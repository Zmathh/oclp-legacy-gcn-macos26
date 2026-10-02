//
// BrcmIOVAFix: packet DMA addresses for the legacy AirPortBrcmNIC on macOS 26 with VT-d on.
//
// Tahoe's x86_64 kernel no longer builds config_mbuf_mcache, so mbuf_data_to_physical()
// returns a raw physical address instead of a system-mapper IOVA. AirPortBrcmNIC's
// osl_dma_map() hands those addresses to the chip, AppleVTD rejects the DMA, and TX hangs.
// We let the original fill its segment table, then replace each physical range by an IOVA
// obtained like the driver's own rings: IODMACommand(kMapped, mapper = NULL). Mappings are
// cached and never released, as mcache did on Sequoia.
//
// osl_dma_map(osh, va, size, dir, pkt, dmah) -> uint64 (segs[0] lo|hi<<32)
//   dmah+0x0c: uint32 nsegs (<= 8); dmah+0x10: segs[i] = { u32 lo, u32 hi, u32 len }, stride 12
//
// STATUS: builds (wifi/BrcmIOVAFix/build.sh); all 307 imports resolve against the macOS 26.0
// kernel + Lilu 1.7.1. Not yet booted.
// Checked in xnu-12377 IOKit: withAddressRange(task = NULL) is kIOMemoryTypePhysical64; physical
// descriptors are mapped with mapper->iovmMapMemory(); IODMACommand(kMapped, mapper = NULL) uses
// IOMapper::gSystem, i.e. what osl_dma_alloc_consistent already relies on for the rings.
//

#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IODMACommand.h>
#include <IOKit/IOMemoryDescriptor.h>

extern "C" boolean_t ml_at_interrupt_context(void);

static const char *bootargOff[]   { "-brcmiovaoff" };
static const char *bootargDebug[] { "-brcmiovadbg" };
static const char *bootargBeta[]  { "-brcmiovabeta" };

static const char *pathBrcmNIC[] {
	"/System/Library/Extensions/IO80211FamilyLegacy.kext/Contents/PlugIns/AirPortBrcmNIC.kext/Contents/MacOS/AirPortBrcmNIC",
};

static KernelPatcher::KextInfo kextBrcmNIC {
	"com.apple.driver.AirPort.BrcmNIC", pathBrcmNIC, arrsize(pathBrcmNIC), {true}, {}, KernelPatcher::KextInfo::Unloaded
};

static constexpr uint64_t PageSize = 4096;
static constexpr size_t BucketCount = 4096;
static constexpr uint32_t MaxSegs = 8;

struct Mapping {
	Mapping *next;
	uint64_t physPage;
	uint32_t pages;
	uint64_t iova;
	IODMACommand *cmd;
	IOMemoryDescriptor *md;
};

static Mapping *buckets[BucketCount];
static IOLock *mapLock;
static uint32_t mapCount, mapFailures, identityMaps, skippedInterrupt;
static mach_vm_address_t orgOslDmaMap;

// Map [first, first + pages * PageSize) once, return its IOVA base, or 0 on failure.
static uint64_t createMapping(uint64_t first, uint32_t pages, IODMACommand **outCmd, IOMemoryDescriptor **outMd) {
	auto md = IOMemoryDescriptor::withAddressRange(first, pages * PageSize, kIODirectionInOut, nullptr);
	if (!md)
		return 0;
	auto cmd = IODMACommand::withSpecification(IODMACommand::OutputHost64, 64, 0, IODMACommand::kMapped, 0, 1, nullptr, nullptr);
	if (!cmd) {
		md->release();
		return 0;
	}
	if (cmd->setMemoryDescriptor(md, true) != kIOReturnSuccess) {
		cmd->release();
		md->release();
		return 0;
	}
	UInt64 offset = 0;
	IODMACommand::Segment64 seg {};
	UInt32 n = 1;
	if (cmd->gen64IOVMSegments(&offset, &seg, &n) != kIOReturnSuccess || n != 1 || seg.fLength != pages * PageSize) {
		cmd->clearMemoryDescriptor();
		cmd->release();
		md->release();
		return 0;
	}
	*outCmd = cmd;
	*outMd = md;
	return seg.fIOVMAddr;
}

static bool translate(uint64_t phys, uint32_t len, uint64_t &iova) {
	uint64_t first = phys & ~(PageSize - 1);
	uint64_t last  = (phys + len - 1) & ~(PageSize - 1);
	uint32_t pages = static_cast<uint32_t>((last - first) / PageSize) + 1;
	size_t b = static_cast<size_t>(((first / PageSize) * 31 + pages) % BucketCount);

	IOLockLock(mapLock);
	for (auto m = buckets[b]; m; m = m->next) {
		if (m->physPage == first && m->pages == pages) {
			iova = m->iova + (phys - first);
			IOLockUnlock(mapLock);
			return true;
		}
	}

	IODMACommand *cmd = nullptr;
	IOMemoryDescriptor *md = nullptr;
	uint64_t base = createMapping(first, pages, &cmd, &md);
	auto m = base ? static_cast<Mapping *>(IOMalloc(sizeof(Mapping))) : nullptr;
	if (!m) {
		mapFailures++;
		IOLockUnlock(mapLock);
		if (mapFailures <= 5)
			SYSLOG("iova", "mapping failed for phys 0x%llx pages %u", first, pages);
		return false;
	}
	*m = { buckets[b], first, pages, base, cmd, md };
	buckets[b] = m;
	mapCount++;
	if (base == first)
		identityMaps++;
	uint32_t count = mapCount, identity = identityMaps;
	IOLockUnlock(mapLock);

	// Powers of two only, so the log shows growth without flooding.
	if ((count & (count - 1)) == 0)
		SYSLOG("iova", "%u mappings (last phys 0x%llx -> iova 0x%llx, %u identity)", count, first, base, identity);
	iova = base + (phys - first);
	return true;
}

static uint64_t wrapOslDmaMap(void *osh, void *va, uint32_t size, int dir, void *pkt, uint8_t *dmah) {
	uint64_t ret = FunctionCast(wrapOslDmaMap, orgOslDmaMap)(osh, va, size, dir, pkt, dmah);
	if (!dmah || !mapLock)
		return ret;
	if (ml_at_interrupt_context()) {
		if (++skippedInterrupt <= 5)
			SYSLOG("iova", "osl_dma_map at interrupt context, left physical");
		return ret;
	}

	uint32_t nsegs = *reinterpret_cast<uint32_t *>(dmah + 0x0c);
	if (nsegs > MaxSegs)
		nsegs = MaxSegs;
	for (uint32_t i = 0; i < nsegs; i++) {
		auto seg = reinterpret_cast<uint32_t *>(dmah + 0x10 + 12 * i);
		uint64_t phys = seg[0] | (static_cast<uint64_t>(seg[1]) << 32);
		uint32_t len = seg[2];
		uint64_t iova;
		if (phys && len && translate(phys, len, iova)) {
			seg[0] = static_cast<uint32_t>(iova);
			seg[1] = static_cast<uint32_t>(iova >> 32);
		}
	}
	return *reinterpret_cast<uint64_t *>(dmah + 0x10);
}

static void processKext(void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
	if (index != kextBrcmNIC.loadIndex)
		return;
	KernelPatcher::RouteRequest request("_osl_dma_map", wrapOslDmaMap, orgOslDmaMap);
	if (!patcher.routeMultiple(index, &request, 1, address, size)) {
		SYSLOG("iova", "failed to route _osl_dma_map: %d", patcher.getError());
		patcher.clearError();
		return;
	}
	SYSLOG("iova", "_osl_dma_map routed");
}

PluginConfiguration ADDPR(config) {
	xStringify(PRODUCT_NAME),
	parseModuleVersion(xStringify(MODULE_VERSION)),
	LiluAPI::AllowNormal | LiluAPI::AllowSafeMode,
	bootargOff, arrsize(bootargOff),
	bootargDebug, arrsize(bootargDebug),
	bootargBeta, arrsize(bootargBeta),
	KernelVersion::Tahoe,
	KernelVersion::Tahoe,
	[]() {
		mapLock = IOLockAlloc();
		lilu.onKextLoadForce(&kextBrcmNIC, 1, processKext, nullptr);
	}
};
