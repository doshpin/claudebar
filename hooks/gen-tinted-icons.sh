#!/bin/bash
# claudebar — pre-generates tinted copies (red/yellow/green/orange) of
# Claude's tray icon (the only bundled asset with real transparency — the
# app icon has a solid background, so tinting it just paints a solid
# square). Uses Cocoa directly via JXA (native, no ImageMagick/PIL
# dependency). Run once; caller skips regenerating if the files exist.

set -e
out_dir="$1"
src="/Applications/Claude.app/Contents/Resources/TrayIconTemplate@2x.png"
[ -f "$src" ] || exit 0
mkdir -p "$out_dir"

osascript -l JavaScript - "$src" "$out_dir" << 'EOF'
ObjC.import('Cocoa');

function tint(srcPath, dstPath, r, g, b) {
  const img = $.NSImage.alloc.initByReferencingFile(srcPath);
  const size = img.size;
  const newImg = $.NSImage.alloc.initWithSize(size);
  newImg.lockFocus;
  img.drawInRectFromRectOperationFraction(
    $.NSMakeRect(0, 0, size.width, size.height),
    $.NSMakeRect(0, 0, size.width, size.height),
    $.NSCompositingOperationSourceOver,
    1.0
  );
  $.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, 1.0).set;
  $.NSRectFillUsingOperation(
    $.NSMakeRect(0, 0, size.width, size.height),
    $.NSCompositingOperationSourceAtop
  );
  newImg.unlockFocus;
  const rep = $.NSBitmapImageRep.imageRepWithData(newImg.TIFFRepresentation);
  const pngData = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
  pngData.writeToFileAtomically(dstPath, true);
}

const args = $.NSProcessInfo.processInfo.arguments;
const src = ObjC.unwrap(args.objectAtIndex(4));
const outDir = ObjC.unwrap(args.objectAtIndex(5));

tint(src, outDir + '/claude-red.png',    0.906, 0.298, 0.235);
tint(src, outDir + '/claude-yellow.png', 0.945, 0.769, 0.059);
tint(src, outDir + '/claude-green.png',  0.180, 0.800, 0.443);
tint(src, outDir + '/claude-orange.png', 0.851, 0.467, 0.341);
EOF
