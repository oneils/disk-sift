---
worth: yes
added: 2026-11-22
---
# Remove selected Neural DSP plugins

Neural DSP ships each plugin (Archetype Nolly X, Morgan Amps Suite and so on) as a set of files spread over system folders, and its only uninstall advice is "delete the files manually in their respective folders" (https://support.neuraldsp.com/help/plugin-file-location). The user wants to pick one plugin and remove just that one, never all Neural DSP plugins at once.

Locations of one plugin, each named after it (checked on the user's Mac):

- AU: `/Library/Audio/Plug-Ins/Components/<Name>.component`
- VST2: `/Library/Audio/Plug-Ins/VST/<Name>.vst`
- VST3: `/Library/Audio/Plug-Ins/VST3/<Name>.vst3`
- AAX: `/Library/Application Support/Avid/Audio/Plug-Ins/<Name>.aaxplugin`
- standalone app: `/Applications/Neural DSP/<Name>.app`
- presets: `/Library/Audio/Presets/Neural DSP/<Name>`
- manual: `/Library/Application Support/Neural DSP/<Name>`
- settings: `~/Library/Application Support/Neural DSP/<Name>` (`<Name>.settings`, `plugin.settings`, `MIDI`)
- package receipts: `com.neuraldsp.<NameWithoutSpaces><AU|VST|VST3|AAX|App|Presets|Manual>.pkg`

Matching by folder or bundle name is enough: the shared `Neural DSP` folders themselves must stay.

Blocker: the plugin bundles sit in `root:wheel` 755 folders, and `RemovalRoots` covers none of the `/Library/Audio` or Avid paths, so DiskSift skips them today. This needs the privileged helper from the v1 plan's "Later" list, the same one deleting Time Machine snapshots waits for. Without it, only the app (in the admin-writable `/Applications/Neural DSP`), the world-writable presets folder and the user settings could be trashed. A partial removal leaves the plugin loadable in a DAW, which is worse than no removal.

Also seen: Gojira X, Rabea X and Fortin Cali Suite are gone, but their manual, settings and receipts are still there, a case for the leftovers scan once system folders are in scope. A general audio-plugin view (any vendor's AU/VST/VST3/AAX) may be the better shape than a Neural DSP special case. Decide when planning.
