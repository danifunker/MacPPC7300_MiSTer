# Prompt for a MacQuadra800_MiSTer session: the ADB game controllers

(Written 2026-10-08 by the PPCMac session, from a read of MacQuadra800_MiSTer
at 58a05e2 while porting its ADB controllers to the PPCMac core. Nothing
here was tested on a board: these are findings from the code and the
protocol notes. Paste everything below the line into a session started in
the Quadra 800 core's repository.)

---

The user reports two problems with the ADB game controllers (`rtl/adb.sv`,
`MacQuadra800.sv` 97-105 and 683-691): **"Stick moves pointer" seems not to
work**, and **the Gravis MouseStick II's axis may be reversed** (the user is
not sure). Check both on the board with a gamepad, fix what is wrong, and
keep the bus unchanged when the controller is "None" and the option is off.

## Stick moves pointer

`rtl/adb.sv` 183-185: the stick reaches the pointer only through the joystick
device (`joy`) in handlers 01/02, and `joy_on` (144) is true only for the
MouseStick II, the Firebird and the SideWinder. With the default
controller, **Gravis GamePad**, or with **None**, the option does nothing at
all. That is probably what the user saw. It also stops once a vendor
driver switches the device's handler (0x23, 0x4E, 0x5D), which is right.

Suggested fix: when the controller has no pointer mode (GamePad, None) and
the option is Yes, add the stick's rate-controlled motion (the same dead
zone and scale as `ptr_dx`/`ptr_dy`, 176-182) to the **mouse** device's Talk 0
(address 3), with joystick button 1 as the mouse button. The mouse must
then raise SRQ while the stick is out of the dead zone. With the GamePad,
take the pointer from the analog stick only and leave the D-pad to the
GamePad's arrow keys. Turn this off once the GamePad's driver has set
handler 0x34. With None, take the pointer from the D-pad or the stick.

If the option also fails with the MouseStick selected, look at what happens
when two devices share address 3: on the board after ADBReInit, check
that the joystick ended up at its own address (Talk 3 to each address) and
that its SRQ is polled.

Also: the controller options sit inside `` `ifndef ETHERNET_OFF ``
(`MacQuadra800.sv` 97). A build without Ethernet loses the menu entries
while `status[46:44]` reads 0, which is the GamePad, so that build always
has a GamePad on the bus.

## The MouseStick II's axes

No sign error is visible in the code:

- tashnotes (`macintosh/adb/protocols/gravis_mousestick_ii.md`): in handler
  0x23's 7-byte Talk 0, X and Y are signed 16-bit, big-endian, 0 at the
  centre, **negative left (X) and up (Y)**, about +-600 at full throw;
  Talk 1 03 00 selects this format (04 00 would select the 3-byte one:
  unsigned, 0x80 the centre, 0x00 left and top).
- The Main sends the analog sticks with **up and left negative**
  (`user_io.cpp`, `user_io_digital_joystick`: left and up become -128).
  `joystick_0`'s [3:0] is {up, down, left, right} from bit 3 down, as
  `adb.sv` reads it.
- `ms_x`/`ms_y` (196-199) are the value x 75 / 16, sign kept, so up is
  negative as documented. The pointer mode's `ptr_dy` is negative up too,
  which is right for an ADB mouse (negative is up).

So if the axis looks reversed, look elsewhere first:

1. The Gravis control panel's own settings: its calibration or axis
   options, and whether it was calibrated with the stick centred.
2. The user's MiSTer joystick mapping: an analog axis can be mapped
   inverted in the Main's controller setup.
3. The MiSTer's Y on that particular pad: print `joystick_l_analog_0` on
   the OSD info line or the debug readout while pushing up.

Only if all three are fine and the cursor or game still goes the wrong
way, flip Y in the 0x23 report (`ms_y`) and note that tashnotes' "negative
is up" was not what the driver expects.

## Test plan (needs the user and a gamepad)

1. Controller None, Stick moves pointer Yes: the pad moves the pointer in
   the Finder, and button 1 clicks.
2. GamePad, Stick moves pointer Yes: the analog stick moves the pointer,
   and the D-pad still gives arrow keys (in the Finder: selection moves).
3. MouseStick II, no Gravis control panel, Yes: the stick moves the
   pointer, and the trigger clicks.
4. MouseStick II with the Gravis control panel (handler 0x23): its test
   panel shows the stick's position. Push up, left, down and right and
   compare.
