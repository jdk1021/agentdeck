#!/usr/bin/env python3
"""Capture README screenshots from the app's synthetic demo mode (no real accounts or data).

Usage: python3 scripts/capture-screenshots.py [path/to/AgentDeckApp [shot ...]]  -> docs/images/*.png
(AGENTDECK_SCREENSHOT_DIR overrides the output folder.)
Requires a logged-in macOS session; the terminal may need Screen Recording permission.
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
APP = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / '.build/debug/AgentDeckApp'
OUT = Path(os.environ.get('AGENTDECK_SCREENSHOT_DIR', ROOT / 'docs/images'))
LOCALE = ['-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
WINDOWS = r'''
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var out: [[String: Any]] = []
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == Int(CommandLine.arguments[1]) && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    out.append(["id": w[kCGWindowNumber as String]!, "name": w[kCGWindowName as String] ?? "", "width": b["Width"] ?? 0])
}
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
'''

SHOTS = [
    ('dashboard-light', ['--demo-appearance', 'light'], 'AgentDeck'),
    ('dashboard-dark', ['--demo-appearance', 'dark'], 'AgentDeck'),
    ('accounts', ['--demo-appearance', 'light', '--demo-select', 'codex', '--demo-scroll', 'accounts'], 'AgentDeck'),
    ('grok', ['--demo-appearance', 'light', '--demo-select', 'grok'], 'AgentDeck'),
    ('openrouter-balance', ['--demo-appearance', 'light', '--demo-select', 'openrouter'], 'AgentDeck'),
    ('panel-light', ['--demo-appearance', 'light', '--panel-preview'], 'AgentDeck Panel'),
    ('panel-dark', ['--demo-appearance', 'dark', '--panel-preview'], 'AgentDeck Panel'),
    ('settings', ['--demo-appearance', 'light', '--demo-settings'], 'settings'),
]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    lister = OUT / '.windows.swift'
    lister.write_text(WINDOWS)
    try:
        wanted = set(sys.argv[2:])
        for name, args, title in SHOTS:
            if wanted and name not in wanted:
                continue
            process = subprocess.Popen([str(APP), '--demo', *args, *LOCALE], cwd=ROOT,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                time.sleep(5)
                windows = json.loads(subprocess.run(['swift', str(lister), str(process.pid)], capture_output=True, text=True, check=True).stdout)
                if title == 'settings':
                    match = [w for w in windows if w['name'] not in ('AgentDeck', 'AgentDeck Panel')]
                else:
                    match = [w for w in windows if w['name'] == title]
                if not any(w['name'] for w in windows):
                    # Without Screen Recording permission (CI runners) window titles are hidden:
                    # match on the windows' fixed widths instead.
                    width = {'AgentDeck': lambda v: v >= 800, 'AgentDeck Panel': lambda v: v == 380, 'settings': lambda v: v == 620}[title]
                    match = [w for w in windows if width(w['width'])]
                if not match:
                    sys.exit(f'{name}: window not found among {windows}')
                subprocess.run(['screencapture', '-x', '-o', '-l', str(match[0]['id']), str(OUT / f'{name}.png')], check=True)
                print('captured', name)
            finally:
                process.terminate(); process.wait(timeout=10)
    finally:
        lister.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
