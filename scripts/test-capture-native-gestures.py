#!/usr/bin/env python3
"""Drive only the synthetic application-hosted archive gesture fixture.

Pass the PID printed by the opt-in IrisTests run. No installed app is launched,
no external menu item is selected, and Quartz events are sent only after verifying that exact process is frontmost.
"""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pid', required=True, type=int)
args = parser.parse_args()
if args.pid <= 0:
    parser.error('PID must be positive')


def apple(source):
    result = subprocess.run(['osascript'], input=source, text=True, capture_output=True, check=True, timeout=5)
    return result.stdout.strip()


def process(source):
    return apple(f'tell application "System Events" to tell (first process whose unix id is {args.pid})\n{source}\nend tell')


def wait_for(check, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if value := check():
                return value
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.1)
    raise RuntimeError('Synthetic fixture did not reach the expected state')


def mouse(phase, label, right=False):
    # Read the rendered text rectangle, not the wider link/form accessibility row.
    bounds = process(f'''set frontmost to true
set nodes to entire contents of window "Archive gesture {phase}"
repeat with node in nodes
 try
  if role of node is "AXStaticText" and value of node is "{label}" then
   return {{position of node, size of node}}
  end if
 end try
end repeat
error "Synthetic link is absent"''')
    x, y, width, height = [float(value.strip()) for value in bounds.split(',')]
    if width <= 0 or height <= 0:
        raise RuntimeError('Synthetic link has no hit target')
    side = 'Right' if right else 'Left'
    source = f'''ObjC.import('AppKit'); ObjC.import('CoreGraphics');
if ($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !== {args.pid}) throw Error('Synthetic app is no longer frontmost');
var point = {{x:{x + width/2},y:{y + height/2}}};
$.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, point, $.kCGMouseButton{side}));
$.NSThread.sleepForTimeInterval(0.1);
var down=$.CGEventCreateMouseEvent(null, $.kCGEvent{side}MouseDown, point, $.kCGMouseButton{side});
$.CGEventSetIntegerValueField(down, $.kCGMouseEventClickState, 1);
$.CGEventPost($.kCGHIDEventTap, down);
$.NSThread.sleepForTimeInterval(0.1);
$.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEvent{side}MouseUp, point, $.kCGMouseButton{side}));'''
    subprocess.run(['osascript', '-l', 'JavaScript'], input=source, text=True, check=True, timeout=5)


def press(phase, label):
    return process(f'''set nodes to entire contents of window "Archive gesture {phase}"
repeat with node in nodes
 try
  if role of node is "AXButton" and name of node is "{label}" then
   click node
   return
  end if
 end try
end repeat
error "Synthetic fixture button is absent"''')


def menu_exists(phase):
    return process(f'exists menu 1 of group 1 of window "Archive gesture {phase}"') == 'true'


for phase in ['control', 'protected']:
    wait_for(lambda: process(f'exists window "Archive gesture {phase}"') == 'true', seconds=15)
    wait_for(lambda: 'Native capture link' in process(f'get entire contents of window "Archive gesture {phase}"'))
    try:
        mouse(phase, 'Native capture link', right=True)
        if phase == 'control':
            wait_for(lambda: menu_exists(phase))
        else:
            # Finite native-menu observation, supplemented by the test observer.
            time.sleep(0.3)
        has_menu = menu_exists(phase)
        print(json.dumps({'phase': phase, 'native_menu': has_menu}), flush=True)
        if has_menu:
            press(phase, "Dismiss context menu")
            # AppKit can retain a dismissed menu in the accessibility tree.
            # The following click must still produce a real sink request.
            time.sleep(0.2)
        mouse(phase, 'Native capture link')
        if phase == 'control':
            wait_for(lambda: 'Native capture link' not in process(f'get entire contents of window "Archive gesture {phase}"'))
        else:
            mouse(phase, 'Native capture download')
            time.sleep(0.3)
    finally:
        # The test checks actual event counts/menu/sink observations. Finishing a
        # failed driver phase cannot turn missing positive controls into a pass.
        press(phase, "Finish " + phase)
