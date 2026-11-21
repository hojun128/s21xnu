#!/bin/bash
# AppleCLCD's display-pipe requirements as dictionaries, the way VideoToolbox reads them:
# FigGetAlignmentForIOSurfaceOutputToDisplayService looks up DisplayPipePlaneBaseAlignment and asks it for
# PlaneBaseAlignmentLinear (then DisplayPipeStrideRequirements / StrideLinearHorizontal). The plain number 64 made
# mediaserverd throw -[__NSCFNumber objectForKey:] as soon as AVPlayer started (run231), so no video played.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
f=iokit/Kernel/arm/SweetFramebuffer.cpp
[[ -f $f ]] || exit 1
grep -q 'setProperty("DisplayPipePlaneBaseAlignment", 64ULL, 32);' "$f" || { echo "0143: DisplayPipePlaneBaseAlignment line not found"; exit 1; }
perl -0pi -e 's/\tsetProperty\("DisplayPipePlaneBaseAlignment", 64ULL, 32\);\n/\t{\n\t\tOSDictionary *al = OSDictionary::withCapacity(1), *sr = OSDictionary::withCapacity(1);\n\t\tOSNumber *n64 = OSNumber::withNumber(64ULL, 32);\n\t\tif (al != NULL && sr != NULL && n64 != NULL) {\n\t\t\tal->setObject("PlaneBaseAlignmentLinear", n64);\n\t\t\tsr->setObject("StrideLinearHorizontal", n64);\n\t\t\tsetProperty("DisplayPipePlaneBaseAlignment", al);\n\t\t\tsetProperty("DisplayPipeStrideRequirements", sr);\n\t\t}\n\t\tOSSafeReleaseNULL(al);\n\t\tOSSafeReleaseNULL(sr);\n\t\tOSSafeReleaseNULL(n64);\n\t}\n/' "$f"
grep -q 'PlaneBaseAlignmentLinear' "$f" || exit 1
echo "0143: display pipe requirements are dictionaries"
