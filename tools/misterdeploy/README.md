# misterdeploy

Reusable tooling to push and launch a [MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/)
core through the **MiSTer Remote** web UI (the [mrext](https://github.com/wizzomafizzo/mrext)
HTTP/websocket API on port `8182`). Not specific to this project — host, port, ssh key,
core filename and folder are all flags/env, so it works for any core on any machine.

## `launch_unstable_core.py`

Pushes a core (optional), then starts it and verifies what launched. Two launch
methods, chosen with `--launch`:

| method | how | when |
|---|---|---|
| **`cmd`** (default with `--ssh-key`) | writes `load_core <path>` to the MiSTer's `/dev/MiSTer_cmd` FIFO over ssh | **use this** — deterministic, no reboot, no menu geometry, no keystroke timing |
| `osd` | reboots for a clean menu, then drives the **main-menu OSD** with generated keystrokes | only when ssh isn't available |

The `osd` path is blind and *does* miss: on `.143` (2026-08-29) it dropped one
keypress at the root menu on both attempts, opening `_Other` instead of `_Unstable`
and launching whatever landed under the cursor. The rest of this section describes
that path, which is unchanged.

The keystroke sequence is **generated at run time from the live menu listing**
(`POST /api/menu/view`), so a core dropped into the folder under any new filename is
found correctly — just pass `--core <filename>`. No menu position is hard-coded; the
downloader re-populating `_Unstable` simply recomputes on the next run.

> The on-screen OSD orders entries **case-insensitively** (`ao486` sorts among the
> `A`s; `wombat33` sorts among the `W`s, after `VIC20`). The API returns them case-*sensitively*,
> so the script re-sorts the filenames itself. A subfolder opens with the cursor on its
> `<UP-DIR>` row, so the core's row is its index + 1 (auto-derived from the `up` field).

### Usage

```bash
# Launch a core already on the MiSTer (host/port from env MISTER_HOST/MISTER_HTTP_PORT):
python launch_unstable_core.py --core wombat33.rbf

# Push a fresh build, then launch it (explicit host + ssh key):
python launch_unstable_core.py --host 192.168.1.50 --ssh-key ~/.ssh/mister \
    --push ./output_files/wombat33.rbf --core wombat33.rbf

# Preview the generated keystrokes without touching anything:
python launch_unstable_core.py --core wombat33.rbf --dry-run
```

### Options (all machine config is a flag or env var)

| flag | env | default | purpose |
|------|-----|---------|---------|
| `--host` | `MISTER_HOST` | `MiSTer.local` | hostname / IP |
| `--port` | `MISTER_HTTP_PORT` | `8182` | MiSTer Remote port |
| `--core` | `RBF_NAME` | — (required) | core filename to launch |
| `--folder` | `MISTER_CORE_FOLDER` | `_Unstable` | top-level `_` folder holding the core |
| `--push FILE` | — | off | scp `FILE` into the folder (md5-verified) first |
| `--ssh-key` | `MISTER_SSH_KEY` | — | ssh identity for `--push` |
| `--ssh-user` | `MISTER_SSH_USER` | `root` | ssh user for `--push` |
| `--launch` | — | `cmd` if `--ssh-key`, else `osd` | `cmd` = /dev/MiSTer_cmd FIFO; `osd` = blind menu nav |
| `--no-reboot` | — | reboots | skip the clean-menu reboot (`osd` path only) |
| `--reboot-wait` | — | `180` | seconds to wait for the web service after reboot |
| `--delay` | — | `0.3` | seconds between key presses |
| `--updir-rows` | `MISTER_OSD_UPDIR_ROWS` | auto | override the `<UP-DIR>` row offset |
| `--no-verify` | — | verifies | skip the post-launch `coreRunning` check |
| `--max-tries` | — | `2` | reboot+select attempts; auto-retries if `coreRunning` misses (blind OSD nav is timing-sensitive) |
| `--dry-run` | — | off | print keystrokes; push/reboot/send nothing |
| `--seed-file FILE` | — | off | local file to seed a save image, **create-only-if-missing** |
| `--seed-remote PATH` | — | — | absolute remote path for `--seed-file` |
| `--seed-mount-cfg PATH` | — | — | absolute remote `.s<N>` mount-memory file to create-if-missing |
| `--seed-mount-rel REL` | — | — | relative path stored in the `.s<N>` file (e.g. `games/Wombat33/QuadSquad8.hda`) |
| `--seed-mount-size N` | — | `1024` | size of the `.s<N>` file (NUL-padded; MiSTer uses 1024) |

**Seeding a save image / disk mount (zero-touch).** `--seed-*` drops a default save file and
pre-writes MiSTer's per-slot mount-memory (`config/<core>.s<N>`) so a save image is
auto-mounted from the first boot with no manual OSD mount. Both are **create-only-if-missing**,
so an existing (saved) file and the user's mount are never overwritten — only the core
itself is always re-pushed. Under git-bash, set `MSYS_NO_PATHCONV=1` so absolute
`/media/fat/...` args aren't rewritten to Windows paths.

Requires `scp`/`ssh` on `PATH` (for `--push`) and the `websockets` Python package.

## `ws_send.py`

Keys, text and the mouse through the Remote's websocket (`/api/ws`): `kbd:<name>`,
`kbdRaw:<code>` (Linux key codes), `kbdRawDown:`/`kbdRawUp:`, `text:<string>` (typed a
key at a time, Shift held for capitals and symbols), `mouseMove:<dx>,<dy>` (relative),
`mouseBtn:left|right|middle`, `sleep:<s>`. The Remote's virtual keyboard and mouse
reach the core as a real USB keyboard and mouse would, through `hps_io`'s PS/2.

In this repo (PPCMac), `syn/mister.py` is the wrapper: `load`, `menu` and `shot` use
the Remote's HTTP API (`/api/launch`, `/api/screenshots`), `ws`, `keys` and `mouse`
this tool; copying files to the card and the UART go over SSH.
