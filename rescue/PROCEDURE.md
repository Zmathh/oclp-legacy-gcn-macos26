# Procédure de secours : macOS 26 ne démarre plus

Deux choses peuvent empêcher Tahoe de démarrer après un essai :

| Ce qui a été modifié | Où | Exemples du 1er et 2 octobre | Commande de secours |
|---|---|---|---|
| La config OpenCore | EFI principal (partition `408679D7…`, `disk0s1` ou `disk1s1` selon le démarrage) : `config.plist`, kexts, quirks, boot-args | `DisableIoMapper=true` : WindowServer plante en boucle à la création de l'écran | `efi` |
| Les fichiers système | Volume système de Tahoe (« Untitled ») : root patch | shim `IO80211` mal signé : blocage à mi-barre, pas d'écran de connexion | `wifi` |

Si tu ne sais pas lequel des deux est en cause, commence par `efi` : c'est rapide et réversible.

## Avant chaque essai

1. Après un démarrage de Tahoe **réussi**, marque la config comme bonne :

   ```bash
   sudo bash ~/oclp-legacy-gcn-macos26/rescue/rescue-tahoe.sh sauver
   ```

   Cette commande crée `config.plist.last-good` (et une copie datée `config.plist.good-AAAAMMJJ-HHMM`) sur l'EFI principal.

2. Ne change qu'**une seule chose** par redémarrage : soit l'EFI, soit le root patch.

## Si Tahoe ne démarre plus

1. **Démarrer Sequoia par l'OpenCore de secours, celui du disque de 1 To** (partition EFI `57A98BC1…`). Allume le Mac en maintenant ⌥ (Option), choisis l'entrée EFI du disque de 1 To, puis « macos stable » dans le menu d'OpenCore. L'OpenCore principal, celui qu'on répare, est sur le disque de 121 Go (partition `408679D7…`). Les deux partitions s'appellent « EFI » : c'est la taille du disque qui les distingue.

2. **Dans Sequoia, ouvre Terminal et fais l'état des lieux** :

   ```bash
   sudo bash /Users/Shared/rescue-tahoe/rescue-tahoe.sh
   ```

   Le script affiche :
   - chaque config présente sur l'EFI principal, avec `DisableIoMapper`, l'état de la pile Wi‑Fi héritée (Tahoe, Sequoia seulement, inactive) et l'état de `BCMWLAN-Block` ;
   - combien de fichiers du root patch Wi‑Fi sont présents sur le volume système de Tahoe.

3. **Réparer :**
   - Config OpenCore en cause : `sudo bash /Users/Shared/rescue-tahoe/rescue-tahoe.sh efi`. Le script remet `config.plist.last-good` et garde la config fautive en `config.plist.failed-DATE`.
   - Root patch en cause : `sudo bash /Users/Shared/rescue-tahoe/rescue-tahoe.sh wifi`. Le script retire les 5 binaires Wi‑Fi, remet le `wifip2pd` d'origine et crée un nouveau snapshot. Le shim GPU n'est pas touché.

4. **Redémarrer sur Tahoe par l'OpenCore principal.**

## À ne pas faire

- **« Revert Root Patches » d'OCLP**, ou `bless … --last-sealed-snapshot` : ça revient au snapshot scellé d'Apple et **retire aussi le shim GPU**.
- **Recopier `config.plist` sur `config.plist.pre-…`** après l'avoir modifié : la sauvegarde contiendrait la version modifiée.

## Où trouver ce kit

| Depuis | Chemin |
|---|---|
| Tahoe | `~/oclp-legacy-gcn-macos26/rescue/` |
| Sequoia | `/Users/Shared/rescue-tahoe/` |
| N'importe quel macOS, après `sudo diskutil mount` de l'EFI principal | `rescue-tahoe/` à la racine de la partition |

Les volumes sont repérés par UUID : les numéros `diskN` ne sont pas les mêmes sous Sequoia et sous Tahoe.
