# F3F-Tool V2
This lua-app for Jeti transmitters is made for gps-based training of RC glider slope racing competitions (F3F) and also distance and speed tasks for F3B.<br>
**All program releases in this 'V2'-repository are only compatible with generation 2 Jeti transmitters (with colour display)!**<br>
For generation 1 Jeti transmitters please use Version 1.x from repository [**F3F-Tool-V1**](https://github.com/frank-sc/F3F-Tool-V1) 

## Program Installation
For installation of a stable release please download the zip-file and the corresponding manual of the newest release from the [**releases-page**](https://github.com/frank-sc/F3F-Tool-V2/releases), download of the 'source code' packages is not necessary. Copy all files and directories into your 'apps' directory on the transmitter, as described in the manual. Then please follow the further steps in the [**F3F-Tool manual**](docs/F3F-Tool%20Manual.md).<br>
**Important: Please use newest Jeti Firmware (currently 5.06 LUA). Older Firmware Versions may cause problems!**

For installation of the current development version (HEAD) please refer to the [**wiki**](https://github.com/frank-sc/F3F-Tool-V2/wiki)

## Status
The tool in Version 2.0 is functionally identical with V1.4 (in Repository [**F3F-Tool-V1**](https://github.com/frank-sc/F3F-Tool-V1), but memory optimization for Generation 1 transmitters was partly removed. Further development on this tool unfortunately can not be done for the old transmitters.

## Changelog V 2.1
General changes:
- improved algorithm for turn line detection, will be more precise if flying further away from the slope or F3B course line.
- some audio changes, for example 'late entry' is announced, adjustment of course is announced im meters
- the second turn in F3B speed mode is alternatively detected by the change of flight direction
- the course can be shifted more than one meter by holding the assigned control
- result times of training flights can be stored in a file for later view

Configuration:
- the 'flight direction' value from gps-sensor should be configured additionally (optional but required). So if it was disabled in the sensor for usage of F3F-Tool V 1.4 it should be enabled again.
- speed-announcement after course entry can be disabled
- 'Center adjust ctrl.' renamed to 'Course adjust ctrl.'
- logging of result times can be activated

Course Setup:
- direct input of slope direction / course direction is possible now, so no need to scan 'Left / Right' if the course is known
- for F3B-course scan now the A-Line is used instead of flight direction

Display:
- 'distance to start' now also is shown in F3B mode
- in F3F mode the current model position (inside or outside course / left or right) is shown
- display was adapted to the new sceen resolution (480*480 px) of 'Jeti DC 24 II' (and probably further new Jeti transmitters), res. is switched automatically.

For further details of the changes refer to the manual.

## Development notices
The main program file 'f3f_\<version\> and the working directory 'f3fTool-\<version\> are always renamed for a new upcoming version. This is to make sure that everything fits together and to allow several versions to run independently on one transmitter.

## Installation of GPS-sensor
Information about choosing a GPS-sensor and the Installation in the glider can be found in the [**wiki**](https://github.com/frank-sc/F3F-Tool-V2/wiki)

## Project Support
If you like the tool you can support my work on the the project by making a donation, i appreciate :)<br><br>
[![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donateCC_LG.gif)](https://www.PayPal.Me/f3frank)<br>

### thanks to
- all donaters, who appreciate my work and help me getting new hardware for testing
- Axel Barnitzke for giving me an idea how to work kind of object-oriented in LUA
- Dave McQueeney for sharing his great Sensor Emulator for Jeti Studio, which allowed me to do a lot of testing on the PC,
and also for bringing up the idea of unloading and reloading parts of code to meet the memory limitations
