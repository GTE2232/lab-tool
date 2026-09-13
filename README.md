irm https://raw.githubusercontent.com/GTE2232/lab-tool/refs/heads/main/lab.ps1 | iex

<div align="center">

# UIT-63 — FDIV Edition

### Lab PC Optimizer for Legacy Windows 10/11 Machines

*Named after the 1994 Intel Pentium FDIV bug — because this tool exists to get correct, reliable performance out of old silicon.*

**made by shivansh**

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?style=flat-square&logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Version](https://img.shields.io/badge/version-1.0.0-blue?style=flat-square)
![Reversible](https://img.shields.io/badge/every%20tweak-reversible-blueviolet?style=flat-square)

</div>

---

## Table of Contents

- [What Is This](#what-is-this)
- [Why It Exists](#why-it-exists)
- [How It Works](#how-it-works)
- [The Operating-System Problem, Explained](#the-operating-system-problem-explained)
- [Quick Start](#quick-start)
- [Manual — Menu Options 1 Through 0](#manual--menu-options-1-through-0)
- [Full Tweak Catalog](#full-tweak-catalog)
- [Running It Safely](#running-it-safely)
- [Safety Model](#safety-model)
- [Requirements](#requirements)
- [Known Limitations & FAQ](#known-limitations--faq)
- [Benefits](#benefits)
- [Roadmap](#roadmap)
- [License](#license)

---

## What Is This

UIT-63 (FDIV Edition) is a single-file, self-elevating PowerShell tool that debloats and optimizes ageing Windows 10/11 machines. It was built for the hardware still common in institute computer labs — older Intel Core processors, 4GB RAM, and mechanical hard disk drives — but applies cleanly to any Windows 10/11 install that's slower than it should be.

It applies a curated set of **reversible, operating-system-level changes** through a simple numbered menu: disabling unnecessary background services, trimming telemetry, tuning storage and memory behaviour, and removing bundled apps that serve no purpose on a coursework machine. Every change is logged and individually undoable.

Rather than a one-shot script, it behaves like a small management console:

```
  +-----------------------------------------------------+
  |         UIT-63 - FDIV Edition | Lab PC Optimizer     |
  +-----------------------------------------------------+
                   made by shivansh

  System Info
  -----------
    OS           : Windows 10 Pro (Build 19045, 64-bit)
    Processor    : Intel(R) Core(TM) i5-2400 @ 3.10GHz
    Cores        : 4C / 4T
    RAM          : 4 GB
    Motherboard  : Dell 0XXXXX

  Main Menu
  ---------
  1. Apply All (base tweaks)
  2. Apply 4GB RAM tweaks (base + RAM tier)
  3. Disable All Applied
  4. Show currently applied / not applied
  5. Apply/Disable individually
  6. Diagnose 'managed by your organization' settings
  7. Restore to a previous save point
  8. Additional tweaks (optional)
  9. Install Windows Apps
  0. Exit
```

---

## Why It Exists

The computer lab this was built for runs on hardware well past its expected service life, with no near-term budget for replacement. The result was a familiar set of complaints — slow boot times, applications freezing mid-use, general frustration during timed coursework — that weren't caused by any single misconfiguration, but by the accumulated weight of background services, telemetry, and default settings that assume much newer hardware than what's actually installed.

This tool exists to address that gap **systematically and reversibly**, rather than through a one-off list of manual registry edits that nobody remembers how to undo six months later.

---

## How It Works

On launch, the script self-elevates (right-click → *Run with PowerShell* triggers its own admin prompt — no manual "Run as Administrator" required), displays live system information, and presents the main menu.

Every tweak is implemented as three linked actions:

| Action | What it does |
|---|---|
| **Check** | Reads the actual current registry/service/filesystem state to report whether the tweak is applied — never assumed, never cached |
| **Apply** | Makes the change (disabling a service, setting a registry value, running a supported system command) |
| **Revert** | Undoes exactly that change, restoring prior behaviour |

Bulk actions (*Apply All*, *Apply 4GB tier*, *Disable All*) run this Check → Apply/Revert logic across every tweak in the group, **skipping anything already in the desired state**. A Windows System Restore point is created automatically before any bulk action, and a save-point system records the full status of every tweak after each run — so the machine's entire configuration can be rolled back to any earlier snapshot, not just factory defaults.

Two settings (font smoothing and DNS) are additionally enforced via **scheduled tasks that reapply at every logon/boot**, since both were observed reverting on some hardware between sessions through mechanisms outside the tool's own runtime — rather than a one-time fix that silently stops working, they self-heal independently of whether the tool is ever opened again.

---

## The Operating-System Problem, Explained

<details>
<summary><strong>Click to expand — the technical background for why this class of hardware freezes and hangs</strong></summary>

<br>

The symptoms reported on this hardware — freezing, hanging, general unresponsiveness — aren't one phenomenon. They're the visible symptom of several distinct, well-understood operating-system behaviours converging on hardware that has too little of every resource (RAM, disk I/O bandwidth, CPU headroom) to absorb their combined cost.

**Race conditions.** Windows runs dozens of background services (telemetry upload, search indexing, prefetch analysis, update delivery) that concurrently compete for the same limited I/O subsystem and CPU scheduler as the user's foreground application. When several attempt overlapping reads/writes to the filesystem or registry at once, the OS serializes access internally — and when this contention is frequent, the visible result is exactly the stutter or "Not Responding" state observed on these machines.

**Deadlock-like contention.** A true deadlock requires four conditions simultaneously (the Coffman conditions: mutual exclusion, hold-and-wait, no preemption, circular wait). The Windows kernel avoids true deadlock in its core subsystems, but the practical symptom users call a "freeze" is very often deadlock-*like* contention — one background service holding a file handle while waiting on disk I/O, while a second process holds a disk queue position waiting on that same handle. The result is functionally identical to a deadlock from the user's perspective. Fewer concurrently active background services means fewer participants in this kind of contention chain.

**Disk scheduling and seek latency.** Mechanical HDDs incur substantial seek time and rotational latency for every I/O request that isn't sequentially adjacent to the last one. Disk scheduling algorithms (FCFS, SSTF, SCAN/elevator, C-SCAN, LOOK) reorder queued requests to minimize head movement — but this only works when the queue actually contains *related* requests. When many unrelated background processes (prefetch analysis, search indexing, telemetry, peer-to-peer update sharing) each issue small, scattered I/O concurrently with the foreground app, the queue becomes densely interleaved with physically distant sectors, defeating the scheduler entirely — a condition informally called disk thrashing. This is the single largest lever available on HDD-based hardware of this generation.

**Memory thrashing.** When the combined working set of active processes exceeds physical RAM, Windows pages memory to disk on demand. On a 4GB machine, this happens fast. When the page-fault rate gets high enough that the CPU spends more time servicing faults — each requiring a disk seek — than executing actual instructions, the system enters thrashing: near-total unresponsiveness, disk light constantly on, almost no forward progress on any application. This is the single most severe failure mode on this hardware class.

**Interrupt handling.** Legacy interrupt delivery multiplexes multiple devices onto a shared IRQ line; the CPU must query every device sharing that line to identify the actual source of each interrupt, adding latency to every I/O completion. Message-Signaled Interrupts (MSI) give each device its own dedicated vector, eliminating that arbitration — directly benefiting storage I/O completion latency on hardware where every operation is already seek-bound.

**Context-switch overhead.** Every thread the scheduler services costs a context switch (register state save/restore). Dozens of largely-idle background services that periodically wake to poll or refresh inflate the thread count the scheduler must service, reducing the CPU time slice actually available to the foreground application.

**NTFS metadata and the Master File Table.** The MFT is NTFS's core metadata structure — one record per file/folder. If its pre-reserved growth zone is exhausted (common with very large numbers of small files, e.g. programming coursework source trees), the MFT extends into general disk space non-contiguously, adding extra seeks to nearly every file operation thereafter.

**Real-time responsiveness vs. average throughput.** A system can have adequate *average* performance while still exhibiting exactly the freezing behaviour reported here, because what's perceived as "hanging" is a worst-case latency spike — a single operation stalling for seconds while disk, memory, or interrupt subsystems are saturated by background contention — not a sustained slowdown. Every tweak in this tool is oriented toward reducing the frequency and severity of these worst-case stalls, not chasing marginal average-case benchmark numbers.

</details>

---

## Quick Start

**Run directly (no download needed):**

```powershell
irm https://your-host/UIT-63-FDIV.ps1 | iex
```

**Or run a local copy:**

```powershell
powershell -ExecutionPolicy Bypass -File "UIT-63-FDIV.ps1"
```

Right-click the script and choose *Run with PowerShell* — it handles its own UAC elevation prompt.

> ⚠️ If you're hosting your own copy for `irm | iex` distribution, set `$ScriptUrl` at the top of the script to your raw file's URL first — it's needed so the elevation step can re-fetch itself in the new admin window.

---

## Manual — Menu Options 1 Through 0

| # | Option | What it does |
|---|---|---|
| **1** | Apply All | Applies every base-tier tweak not already active. Creates a restore point first. |
| **2** | Apply 4GB RAM Tweaks | Runs everything in Option 1, then applies the additional tier tuned specifically for 4GB-RAM machines. |
| **3** | Disable All Applied | Reverts every currently active tweak back to Windows default, in one pass. |
| **4** | Show Status | Live, colour-coded status for every tweak — green = applied, grey = not applied. Read-only. |
| **5** | Apply/Disable Individually | Toggle any single tweak by number, leaving everything else untouched. |
| **6** | Diagnose Managed Settings | Checks for domain/MDM policy conflicts and explains "managed by your organization" labels. |
| **7** | Restore to a Save Point | Roll the entire tweak configuration back to any previous automatic snapshot. |
| **8** | Additional Tweaks | Photo Viewer restoration, DNS provider (Google/Cloudflare), Wi-Fi MAC randomization — applied individually, not in bulk. |
| **9** | Install Windows Apps | Reinstall anything the tool removed, individually or all at once, via winget/Microsoft Store. |
| **0** | Exit | Closes the tool. |

---

## Full Tweak Catalog

<details>
<summary><strong>4.1 — Background Services</strong></summary>

| Tweak | What it does and why |
|---|---|
| SysMain (Superfetch) off | Stops RAM-based app prefetching that competes with foreground apps for scarce 4GB RAM. |
| DiagTrack (Telemetry) off | Stops the standing diagnostic-data collection and upload service. |
| Xbox services off | Removes gaming-authentication/networking services never used on lab desktops. |
| Delivery Optimization: HTTP only | Stops the machine sharing Windows Update data with other PCs over the network. |
| Remote Registry off | Closes an unused remote-administration service, reducing attack surface. |
| Downloaded Maps Manager off | Stops background offline-map downloads irrelevant to a desktop lab machine. |
| Fax service off | Removes legacy fax support with no modern hardware to use it. |
| Retail Demo off | Removes the retail-display kiosk mode. |
| WAP Push service off | Removes a legacy carrier-provisioning/telemetry channel. |

</details>

<details>
<summary><strong>4.2 — Privacy and Telemetry</strong></summary>

| Tweak | What it does and why |
|---|---|
| Bing in search off | Keeps Start/Explorer search local instead of a network round-trip. |
| Feedback frequency: Never | Stops periodic feedback-request interruptions. |
| Activity History off | Stops recording and uploading cross-device usage history. |
| Diagnostic data: Basic | Reduces telemetry volume collected and transmitted. |
| Advertising ID off | Disables cross-app ad-personalization tracking. |
| Tailored Experiences off | Stops diagnostic-data-driven suggestion generation. |
| Windows Copilot off | Removes the AI assistant's background footprint. |
| Cortana off | Removes the legacy voice-assistant subsystem. |
| Storage Sense off | Stops automatic background disk scans (documented trade-off on HDDs — see FAQ). |

</details>

<details>
<summary><strong>4.3 — Visual Effects and Power</strong></summary>

| Tweak | What it does and why |
|---|---|
| Memory Integrity (Core Isolation) off | Removes hypervisor-based memory-protection overhead poorly suited to this CPU generation (documented security trade-off). |
| Background apps off | Stops UWP apps running/updating while not in focus. |
| Power plan: High Performance | Avoids CPU downclocking latency between bursts of activity. |
| Custom visual effects | Trims compositing-heavy effects (menu fade, combo-box slide, cursor shadow) while explicitly keeping font smoothing, control animation, and window shadows on. |
| Transparency off | Removes GPU/CPU-intensive blur compositing. |
| Explorer thumbnails off | Shows generic icons instead of decoding file contents to populate a folder view. |
| Hibernation off | Frees disk space, removes Fast Startup's hybrid-boot complexity. |

</details>

<details>
<summary><strong>4.4 — Storage and Filesystem</strong></summary>

| Tweak | What it does and why |
|---|---|
| NTFS last-access timestamps off | Stops every file read silently becoming a read-plus-metadata-write. |
| MSI interrupts for AHCI controller | Dedicated interrupt vector instead of a shared line, cutting per-I/O latency. |
| MFT zone reservation increased | Reduces Master File Table fragmentation on volumes with very large numbers of small files. |
| NTFS metadata cache: maximum | Caches more filesystem metadata in RAM, reducing repeated disk lookups. |
| 8.3 short filenames off | Removes legacy DOS-compatible filename generation on every file creation. |

</details>

<details>
<summary><strong>4.5 — 4GB RAM Tier (Option 2 only)</strong></summary>

| Tweak | What it does and why |
|---|---|
| Program Compatibility Assistant off | Removes a background compatibility-monitoring service. |
| SvcHost split threshold raised | Groups more services into shared processes, reducing per-process memory overhead. |
| Fixed pagefile (4096–8192MB) | Avoids fragmentation and resize-stall risk from a dynamically-sized pagefile. |

</details>

<details>
<summary><strong>4.6 — Further Background Tasks and App Removal</strong></summary>

| Tweak | What it does and why |
|---|---|
| Edge preloading / startup boost off | Stops Edge pre-launching itself in the background at every boot. |
| Shared Experiences off | Disables cross-device continuity features and their background tasks. |
| Automatic Maps updates off | Stops background map-data updates. |
| Location tracking off | Disables system-wide location services. |
| Mobile broadband metadata task off | Removes a background task irrelevant to non-cellular desktops. |
| Speech model download task off | Stops background download of speech-recognition data. |
| ~40 bundled apps removed | Xbox suite, Bing content apps, Skype, Wallet, Whiteboard, Maps, Zune Music/Video, Phone Link, Copilot, and more — reinstall any of them from Option 9. |

</details>

<details>
<summary><strong>4.7 — Additional, Opt-In Tweaks (Option 8)</strong></summary>

| Tweak | What it does and why |
|---|---|
| Photo Viewer restoration | Registers the lightweight legacy viewer as selectable; setting it fully default needs one manual confirmation due to Windows' own anti-hijack protection on `UserChoice`. |
| DNS provider (Google/Cloudflare) | Reduces resolution latency versus a slow default resolver; self-heals via a startup task since some hardware loses manual DNS settings across reboots. |
| MAC randomisation | Randomises the Wi-Fi hardware address per network, where the driver supports it. |

</details>

---

## Running It Safely

- Right-click the script and choose **Run with PowerShell**. Approve the UAC prompt — the tool needs administrator rights, same as installing any desktop program.
- On first run, start with **Option 1** only. Don't enable the 4GB RAM tier (**Option 2**) unless the machine genuinely has 4GB of RAM or less.
- A System Restore point is created automatically before any bulk change.
- Use **Option 4** any time to review exactly what's currently applied before making further changes.
- Unsure about a specific tweak? Apply it individually via **Option 5** and observe the machine for a day before applying the rest.
- To fully undo everything: **Option 3** (Disable All Applied), or **Option 7** to restore a save point from before any changes were made.
- **No option disables Windows Defender, Windows Update, SmartScreen, or CPU security mitigations** — deliberate, so the tool stays safe on internet-connected, multi-user machines.

**Compatibility note:** built and tested primarily on Windows 10. Most tweaks use mechanisms (registry policies, service configuration, NTFS/fsutil behaviour) unchanged on Windows 11, so it's expected to work there — but treat a Windows 11 machine as a first-time test case, not an assumed identical target.

---

## Safety Model

- ✅ System Restore checkpoint before any bulk action
- ✅ Live status checking — never a cached assumption
- ✅ Every tweak individually reversible, in addition to bulk apply/disable
- ✅ Full timestamped audit log (`prev.txt` on the Desktop) for fleet-wide accountability
- ✅ Save-point snapshots after every bulk action — roll back to *any* previous state, not just factory defaults
- ❌ Nothing here touches antivirus, Windows Update, SmartScreen, or CPU vulnerability mitigations — by design, not by omission

---

## Requirements

- Windows 10 (primary target) or Windows 11 (expected to work, less extensively tested)
- PowerShell 5.1 (ships with Windows 10/11 by default)
- Administrator rights (the script handles elevation itself)

---

## Known Limitations & FAQ

**Will this break anything?**
Every tweak is reversible, and a restore point is created before bulk changes. Test on one machine before fleet-wide deployment.

**Why isn't Windows Photo Viewer set as default automatically?**
Windows deliberately protects default-app associations (`UserChoice`) from unattended changes, specifically to stop malware from hijacking them — the same protection blocks *every* script, including this one, from forcing an override on an already-established profile. The tool registers Photo Viewer as selectable and opens Settings for you; the final click is yours.

**Some settings show "managed by your organization" and won't change — why?**
That label appears whenever a setting lives in the Group Policy registry path, whether written by a domain controller or by this tool. Use **Option 6** to check whether it's a real policy conflict.

**DNS settings disappeared after a reboot — is that a bug?**
On some hardware, interface index renumbering (or a router/domain policy) can revert manually-set DNS across reboots. Setting DNS via Option 8 now also registers a startup task that reapplies it automatically — if it still reverts after that, it likely indicates a domain/router-level policy overriding it, not a local Windows quirk.

**Is Storage Sense off actually a good idea?**
It's a documented trade-off, not a strict win — disabling it removes a background disk-scanning source, but on an HDD genuinely short on space, Storage Sense's automatic cleanup can be more helpful than harmful. Judge by your actual disk headroom.

---

## Benefits

**To the maintainer:** a reusable, documented tool instead of a one-time manual fix, applicable to any similar machine going forward — and hands-on practice with Windows internals (services, registry, NTFS behaviour, Group Policy mechanisms) beyond typical coursework.

**To the institute:** a no-cost way to extend the usable life of existing lab hardware without a hardware refresh budget, with a consistent, auditable configuration applicable uniformly across every machine — and every change stays reversible, so IT staff are never left with an undocumented system state.

**To students:** fewer freezes and shorter wait times during lab sessions, directly reducing time lost during timed practicals and assignments, and a more consistent experience across machines rather than some being noticeably worse than others.

---

## Roadmap

- [ ] Windows 11 compatibility pass
- [ ] Config file support for unattended fleet deployment
- [ ] Optional CSV export of applied-tweak status across machines

---

## License

MIT — use it, fork it, deploy it across your own lab.

<div align="center">

---

**UIT-63 — FDIV Edition** · made by shivansh

*If it helped your lab, a ⭐ is appreciated.*

</div>
