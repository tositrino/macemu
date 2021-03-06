/*
 *	clip_macosx64.mm - Clipboard handling, MacOS X (Pasteboard Manager) implementation
 *
 *	(C) 2012 Jean-Pierre Stierlin
 *	(C) 2012 Alexei Svitkine
 *	(C) 2012 Charles Srstka
 *
 *	This program is free software; you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation; either version 2 of the License, or
 *	(at your option) any later version.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program; if not, write to the Free Software
 *	Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include "sysdeps.h"
#define _UINT64
#import <Cocoa/Cocoa.h>
#include <ApplicationServices/ApplicationServices.h>

#include "clip.h"
#include "main.h"
#include "cpu_emulation.h"
#include "emul_op.h"
#include "autorelease.h"

#define DEBUG 0
#include "debug.h"

#ifndef FOURCC
#define FOURCC(a,b,c,d) (((uint32)(a) << 24) | ((uint32)(b) << 16) | ((uint32)(c) << 8) | (uint32)(d))
#endif

#define TYPE_PICT FOURCC('P','I','C','T')
#define TYPE_TEXT FOURCC('T','E','X','T')
#define TYPE_STYL FOURCC('s','t','y','l')

static NSPasteboard *g_pboard;

// Flag for PutScrap(): the data was put by GetScrap(), don't bounce it back to the MacOS X side
static bool we_put_this_data = false;

static bool should_clear = false;

static NSMutableDictionary *macScrap;

// flavor UTIs

static NSString * const UTF16_TEXT_FLAVOR_NAME = @"public.utf16-plain-text";
static NSString * const TEXT_FLAVOR_NAME = @"com.apple.traditional-mac-plain-text";
static NSString * const STYL_FLAVOR_NAME = @"net.cebix.basilisk.styl-data";

// font face types

enum {
	FONT_FACE_PLAIN = 0,
	FONT_FACE_BOLD = 1,
	FONT_FACE_ITALIC = 2,
	FONT_FACE_UNDERLINE = 4,
	FONT_FACE_OUTLINE = 8,
	FONT_FACE_SHADOW = 16,
	FONT_FACE_CONDENSED = 32,
	FONT_FACE_EXTENDED = 64
};

// Script Manager constants

#define smRoman 			0
#define smMacSysScript		18
#define smMacRegionCode		40

static NSString *GetUTIFromFlavor(uint32_t type)
{
	switch (type) {
		case TYPE_PICT: return (NSString *)kUTTypePICT;
		case TYPE_TEXT: return TEXT_FLAVOR_NAME;
			//case TYPE_TEXT: return UTF16_TEXT_FLAVOR_NAME;
		case TYPE_STYL: return STYL_FLAVOR_NAME;
		case FOURCC('m','o','o','v'): return (NSString *)kUTTypeQuickTimeMovie;
		case FOURCC('s','n','d',' '): return (NSString *)kUTTypeAudio;
			//case FOURCC('u','t','x','t'): return UTF16_TEXT_FLAVOR_NAME;
		case FOURCC('u','t','1','6'): return UTF16_TEXT_FLAVOR_NAME;
			//case FOURCC('u','s','t','l'): return @"????";
		case FOURCC('i','c','n','s'): return (NSString *)kUTTypeAppleICNS;
		default: return nil;
	}
}

/*
 *	Get current system script encoding on Mac
 */

static int GetMacScriptManagerVariable(uint16_t varID)
{
	int ret = -1;
	M68kRegisters r;
	static uint8_t proc[] = {
		0x59, 0x4f,							// subq.w	 #4,sp
		0x3f, 0x3c, 0x00, 0x00,				// move.w	 #varID,-(sp)
		0x2f, 0x3c, 0x84, 0x02, 0x00, 0x08, // move.l	 #-2080243704,-(sp)
		0xa8, 0xb5,							// ScriptUtil()
		0x20, 0x1f,							// move.l	 (a7)+,d0
		M68K_RTS >> 8, M68K_RTS & 0xff
	};
	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];
	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		WriteMacInt16(proc_area + 4, varID);
		Execute68k(proc_area, &r);
		ret = r.d[0];
		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}
	return ret;
}

static ScriptCode ScriptNumberForFontID(int16_t fontID)
{
	ScriptCode ret = -1;
	M68kRegisters r;
	static uint8_t proc[] = {
		0x55, 0x4f,							// subq.w	#2,sp
		0x3f, 0x3c, 0x00, 0x00,				// move.w	#fontID,-(sp)
		0x2f, 0x3c, 0x82, 0x02, 0x00, 0x06, // move.l	#-2113798138,-(sp)
		0xa8, 0xb5,							// ScriptUtil()
		0x30, 0x1f,							// move.w	(sp)+,d0
		M68K_RTS >> 8, M68K_RTS & 0xff
	};
	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];
	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		WriteMacInt16(proc_area + 4, fontID);
		Execute68k(proc_area, &r);
		ret = r.d[0];
		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}
	return ret;
}

/*
 * Get Mac's default text encoding
 */

static TextEncoding MacDefaultTextEncoding()
{
	int script = GetMacScriptManagerVariable(smMacSysScript);
	int region = GetMacScriptManagerVariable(smMacRegionCode);
	TextEncoding encoding;

	if (UpgradeScriptInfoToTextEncoding(script, kTextLanguageDontCare, region, NULL, &encoding))
		encoding = kTextEncodingMacRoman;

	return encoding;
}

static NSData *ConvertToMacTextEncoding(NSAttributedString *aStr, NSArray **styleAndScriptRuns)
{
	NSUInteger length = [aStr length];

	NSMutableArray *styleRuns = [NSMutableArray array];

	for (NSUInteger index = 0; index < length;) {
		NSRange attrRange;
		NSDictionary *attrs = [aStr attributesAtIndex:index effectiveRange:&attrRange];

		[styleRuns addObject:[NSDictionary dictionaryWithObjectsAndKeys:
							  [NSNumber numberWithUnsignedInteger:index], @"offset",
							  attrs, @"attributes", nil]];

		index = NSMaxRange(attrRange);
	}

	UnicodeToTextRunInfo info;

	OSStatus err = CreateUnicodeToTextRunInfoByScriptCode(0, NULL, &info);

	if (err != noErr) {
		if (styleAndScriptRuns)
			*styleAndScriptRuns = styleRuns;

		return [[aStr string] dataUsingEncoding:CFStringConvertEncodingToNSStringEncoding(MacDefaultTextEncoding())];
	}

	unichar chars[length];

	[[aStr string] getCharacters:chars range:NSMakeRange(0, length)];

	NSUInteger unicodeLength = length * sizeof(unichar);
	NSUInteger bufLen = unicodeLength * 2;
	uint8_t buf[bufLen];
	ByteCount bytesRead;

	ItemCount scriptRunCount = 1601; // max number of allowed style changes
	ScriptCodeRun scriptRuns[scriptRunCount];

	ItemCount inOffsetCount = [styleRuns count];
	ByteOffset inOffsets[inOffsetCount];

	if (inOffsetCount) {
		for (NSUInteger i = 0; i < inOffsetCount; i++) {
			NSDictionary *eachRun = [styleRuns objectAtIndex:i];

			inOffsets[i] = [[eachRun objectForKey:@"offset"] unsignedLongValue] * 2;
		}
	}

	ItemCount offsetCount;
	ByteOffset offsets[inOffsetCount];

	err = ConvertFromUnicodeToScriptCodeRun(info, unicodeLength, chars,
											kUnicodeTextRunMask | kUnicodeUseFallbacksMask | kUnicodeLooseMappingsMask,
											inOffsetCount, inOffsets, &offsetCount, offsets,
											bufLen, &bytesRead, &bufLen, buf,
											scriptRunCount, &scriptRunCount, scriptRuns);

	if (err != noErr) {
		if (styleAndScriptRuns)
			*styleAndScriptRuns = styleRuns;

		return [[aStr string] dataUsingEncoding:CFStringConvertEncodingToNSStringEncoding(MacDefaultTextEncoding())];
	}

	if (styleAndScriptRuns) {
		NSMutableArray *runs = [NSMutableArray array];
		NSUInteger currentStyleRun = 0;
		NSUInteger currentScriptRun = 0;

		for (NSUInteger currentOffset = 0; currentOffset < bufLen;) {
			ScriptCodeRun scriptRun = scriptRuns[currentScriptRun];
			NSDictionary *attrs = [[styleRuns objectAtIndex:currentStyleRun] objectForKey:@"attributes"];

			NSUInteger nextStyleOffset = (currentStyleRun < offsetCount - 1) ? offsets[currentStyleRun + 1] : bufLen;
			NSUInteger nextScriptOffset = (currentScriptRun < scriptRunCount - 1) ? scriptRuns[currentScriptRun + 1].offset : bufLen;

			[runs addObject:[NSDictionary dictionaryWithObjectsAndKeys:
							 [NSNumber numberWithUnsignedInteger:currentOffset], @"offset",
							 [NSNumber numberWithShort:scriptRun.script], @"script",
							 attrs, @"attributes", nil]];

			if (nextStyleOffset == nextScriptOffset) {
				currentStyleRun++;
				currentScriptRun++;
				currentOffset = nextStyleOffset;
			} else if (nextStyleOffset < nextScriptOffset) {
				currentStyleRun++;
				currentOffset = nextStyleOffset;
			} else {
				currentScriptRun++;
				currentOffset = nextScriptOffset;
			}
		}

		*styleAndScriptRuns = runs;
	}

	return [NSData dataWithBytes:buf length:bufLen];
}

/*
 * Count all Mac font IDs on the system
 */

static NSUInteger CountMacFonts()
{
	M68kRegisters r;
	static uint8_t proc[] = {
		0x55, 0x4f,						// subq.w	#2,sp
		0x2f, 0x3c, 'F', 'O', 'N', 'D',	// move.l	#'FOND',-(sp)
		0xa9, 0x9c,						// CountResources()
		0x30, 0x1f,						// move.w (sp)+,D0
		M68K_RTS >> 8, M68K_RTS & 0xff
	};
	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];
	int16_t fontCount = 0;

	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		Execute68k(proc_area, &r);

		fontCount = r.d[0];

		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}

	if (fontCount < 0) {
		fontCount = 0;
	}

	return fontCount;
}

/*
 * Get Mac font ID at index
 */

static int16_t MacFontIDAtIndex(NSUInteger index)
{
	M68kRegisters r;
	static uint8_t get_res_handle_proc[] = {
		0x42, 0x27,						// clr.b	-(sp)
		0xa9, 0x9b,						// SetResLoad()
		0x59, 0x4f,						// subq.w	#4,sp
		0x2f, 0x3c, 'F', 'O', 'N', 'D',	// move.l	#'FOND',-(sp)
		0x3f, 0x3c,	0, 0,				// move.w	#index,-(sp)
		0xa9, 0x9d,						// GetIndResource()
		0x26, 0x5f,						// movea.l	(sp)+,A3
		0x1f, 0x3c, 0x00, 0x01,			// move.b	#1,-(sp)
		0xa9, 0x9b,						// SetResLoad()
		M68K_RTS >> 8, M68K_RTS & 0xff
	};
	r.d[0] = sizeof(get_res_handle_proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];

	uint32_t res_handle = 0;
	int16_t fontID = 0;

	if (proc_area) {
		Host2Mac_memcpy(proc_area, get_res_handle_proc, sizeof(get_res_handle_proc));
		WriteMacInt16(proc_area + 14, (uint16_t)(index + 1));

		Execute68k(proc_area, &r);

		res_handle = r.a[3];

		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr()
	}

	if (res_handle) {
		static uint8_t get_info_proc[] = {
			0x2f, 0x0a,						// move.l	A2,-(sp)
			0x2f, 0x0b,						// move.l	A3,-(sp)
			0x42, 0xa7,						// clr.l	-(sp)
			0x42, 0xa7,						// clr.l	-(sp)
			0xa9, 0xa8,						// GetResInfo()
			0x2f, 0x0a,						// move.l	A2,-(sp)
			0xa9, 0xa3,						// ReleaseResource()
			M68K_RTS >> 8, M68K_RTS & 0xff,
			0, 0
		};

		r.d[0] = sizeof(get_info_proc);
		Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
		proc_area = r.a[0];

		if (proc_area) {
			Host2Mac_memcpy(proc_area, get_info_proc, sizeof(get_info_proc));
			r.a[2] = res_handle;
			r.a[3] = proc_area + 16;

			Execute68k(proc_area, &r);

			fontID = ReadMacInt16(proc_area + 16);

			r.a[0] = proc_area;
			Execute68kTrap(0xa01f, &r);	// DisposePtr()
		}
	}

	return fontID;
}

/*
 * List all font IDs on the system
 */

static NSArray *ListMacFonts()
{
	NSUInteger fontCount = CountMacFonts();
	NSMutableArray *fontIDs = [NSMutableArray array];

	for (NSUInteger i = 0; i < fontCount; i++) {
		int16_t eachFontID = MacFontIDAtIndex(i);

		[fontIDs addObject:[NSNumber numberWithShort:eachFontID]];
	}

	return fontIDs;
}

/*
 * List all font IDs having a certain script
 */

static NSArray *ListMacFontsForScript(ScriptCode script)
{
	NSMutableArray *fontIDs = [NSMutableArray array];

	for (NSNumber *eachFontIDNum in ListMacFonts()) {
		if (ScriptNumberForFontID([eachFontIDNum shortValue]) == script)
			[fontIDs addObject:eachFontIDNum];
	}

	return fontIDs;
}

/*
 * Convert Mac font ID to font name
 */

static NSString *FontNameFromFontID(int16_t fontID)
{
	M68kRegisters r;
	r.d[0] = 256;					// Str255: 255 characters + length byte
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t name_area = r.a[0];

	if (!name_area)
		return nil;

	uint8_t proc[] = {
		0x3f, 0x3c, 0, 0,	// move.w	#fontID,-(sp)
		0x2f, 0x0a,			// move.l	A2,-(sp)
		0xa8, 0xff,			// GetFontName()
		M68K_RTS >> 8, M68K_RTS & 0xff
	};

	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];

	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		WriteMacInt16(proc_area + 2, fontID);
		r.a[2] = name_area;
		Execute68k(proc_area, &r);

		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}

	uint8_t * const namePtr = Mac2HostAddr(name_area);

	NSString *name = (NSString *)CFStringCreateWithPascalString(kCFAllocatorDefault, namePtr, kCFStringEncodingMacRoman);

	r.a[0] = name_area;
	Execute68kTrap(0xa01f, &r);			// DisposePtr

	return [name autorelease];
}

/*
 * Convert font name to Mac font ID
 */

static int16_t FontIDFromFontName(NSString *fontName)
{
	M68kRegisters r;
	r.d[0] = 256;					// Str255: 255 characters + length byte
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t name_area = r.a[0];

	if (!name_area)
		return 0;

	uint8_t * const namePtr = Mac2HostAddr(name_area);

	CFStringGetPascalString((CFStringRef)fontName, namePtr, 256, kCFStringEncodingMacRoman);

	uint8_t proc[] = {
		0x2f, 0x0a,			// move.l	A2,-(sp)
		0x2f, 0x0b,			// move.l	A3,-(sp)
		0xa9, 0x00,			// GetFNum()
		M68K_RTS >> 8, M68K_RTS & 0xff,
		0, 0
	};

	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];
	int16_t fontID = 0;

	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		r.a[2] = name_area;
		r.a[3] = proc_area + 8;

		Execute68k(proc_area, &r);

		fontID = ReadMacInt16(proc_area + 8);

		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}

	r.a[0] = name_area;
	Execute68kTrap(0xa01f, &r);			// DisposePtr

	return fontID;
}

/*
 * Get font ID in desired script if possible; otherwise, try to get some font in the desired script.
 */

static int16_t FontIDFromFontNameAndScript(NSString *fontName, ScriptCode script)
{
	int16_t fontID = FontIDFromFontName(fontName);

	if (ScriptNumberForFontID(fontID) == script)
		return fontID;

	NSArray *fontIDs = ListMacFontsForScript(script);

	if ([fontIDs count] == 0)
		return fontID; // no fonts are going to work; might as well return the original one

	if (fontName) {
		// look for a localized version of our font; e.g. "Helvetica CE" if our font is Helvetica
		for (NSNumber *eachFontIDNum in fontIDs) {
			int16_t eachFontID = [eachFontIDNum shortValue];

			if ([FontNameFromFontID(eachFontID) hasPrefix:fontName])
				return eachFontID;
		}
	}

	// Give up and just return a font that will work
	return [[fontIDs objectAtIndex:0] shortValue];
}

/*
 * Convert Mac TEXT/styl to attributed string
 */

static NSAttributedString *AttributedStringFromMacTEXTAndStyl(NSData *textData, NSData *stylData)
{
	NSMutableAttributedString *aStr = [[[NSMutableAttributedString alloc] init] autorelease];

	if (aStr == nil)
		return nil;

	const uint8_t *bytes = (const uint8_t *)[stylData bytes];
	NSUInteger length = [stylData length];

	if (length < 2)
		return nil;

	uint16_t elements = CFSwapInt16BigToHost(*(uint16_t *)bytes);
	const NSUInteger elementSize = 20;

	if (length < elements * elementSize)
		return nil;

	NSUInteger pointer = 2;

	for (NSUInteger i = 0; i < elements; i++) AUTORELEASE_POOL {
		int32_t startChar = CFSwapInt32BigToHost(*(int32_t *)(bytes + pointer)); pointer += 4;
		int16_t height __attribute__((unused)) = CFSwapInt16BigToHost(*(int16_t *)&bytes[pointer]); pointer += 2;
		int16_t ascent __attribute__((unused)) = CFSwapInt16BigToHost(*(int16_t *)&bytes[pointer]); pointer += 2;
		int16_t fontID = CFSwapInt16BigToHost(*(int16_t *)&bytes[pointer]); pointer += 2;
		uint8_t face = bytes[pointer]; pointer += 2;
		int16_t size = CFSwapInt16BigToHost(*(int16_t *)&bytes[pointer]); pointer += 2;
		uint16_t red = CFSwapInt16BigToHost(*(int16_t *)&bytes[pointer]); pointer += 2;
		uint16_t green = CFSwapInt16BigToHost(*(int16_t *)&bytes[pointer]); pointer += 2;
		uint16_t blue = CFSwapInt16BigToHost(*(int16_t *)&bytes[pointer]); pointer += 2;

		int32_t nextChar;

		if (i + 1 == elements)
			nextChar = [textData length];
		else
			nextChar = CFSwapInt32BigToHost(*(int32_t *)(bytes + pointer));

		NSMutableDictionary *attrs = [[NSMutableDictionary alloc] init];
		NSColor *color = [NSColor colorWithDeviceRed:(CGFloat)red / 65535.0 green:(CGFloat)green / 65535.0 blue:(CGFloat)blue / 65535.0 alpha:1.0];
		NSFont *font;
		TextEncoding encoding;

		if (fontID == 0) {			// System font
			CGFloat fontSize = (size == 0) ? [NSFont systemFontSize] : (CGFloat)size;
			font = [NSFont systemFontOfSize:fontSize];
		} else if (fontID == 1) {	// Application font
			font = [NSFont userFontOfSize:(CGFloat)size];
		} else {
			NSString *fontName = FontNameFromFontID(fontID);
			font = [NSFont fontWithName:fontName size:(CGFloat)size];

			if (font == nil) {
				// Convert localized variants of fonts; e.g. "Helvetica CE" to "Helvetica"

				NSRange wsRange = [fontName rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet] options:NSBackwardsSearch];

				if (wsRange.length) {
					fontName = [fontName substringToIndex:wsRange.location];
					font = [NSFont fontWithName:fontName size:(CGFloat)size];
				}
			}
		}

		if (font == nil)
			font = [NSFont userFontOfSize:(CGFloat)size];

		if (UpgradeScriptInfoToTextEncoding(ScriptNumberForFontID(fontID), kTextLanguageDontCare, kTextRegionDontCare, NULL, &encoding))
			encoding = MacDefaultTextEncoding();

		NSFontManager *fm = [NSFontManager sharedFontManager];

		if (face & FONT_FACE_BOLD)
			font = [fm convertFont:font toHaveTrait:NSBoldFontMask];

		if (face & FONT_FACE_ITALIC)
			font = [fm convertFont:font toHaveTrait:NSItalicFontMask];

		if (face & FONT_FACE_CONDENSED)
			font = [fm convertFont:font toHaveTrait:NSCondensedFontMask];

		if (face & FONT_FACE_EXTENDED)
			font = [fm convertFont:font toHaveTrait:NSExpandedFontMask];

		[attrs setObject:font forKey:NSFontAttributeName];

		if (face & FONT_FACE_UNDERLINE)
			[attrs setObject:[NSNumber numberWithInteger:NSUnderlineStyleSingle] forKey:NSUnderlineStyleAttributeName];

		if (face & FONT_FACE_OUTLINE) {
			[attrs setObject:color forKey:NSStrokeColorAttributeName];
			[attrs setObject:[NSNumber numberWithInteger:3] forKey:NSStrokeWidthAttributeName];
		}

		if (face & FONT_FACE_SHADOW) {
			NSShadow *shadow = [[NSShadow alloc] init];
			NSColor *shadowColor = [NSColor colorWithDeviceRed:(CGFloat)red / 65535.0 green:(CGFloat)green / 65535.0 blue:(CGFloat)blue / 65535.0 alpha:0.5];

			[shadow setShadowColor:shadowColor];
			[shadow setShadowOffset:NSMakeSize(2, -2.0)];

			[attrs setObject:shadow forKey:NSShadowAttributeName];

			[shadow release];
		}

		[attrs setObject:color forKey:NSForegroundColorAttributeName];

		NSData *partialData = [textData subdataWithRange:NSMakeRange(startChar, nextChar - startChar)];
		NSString *partialString = [[NSString alloc] initWithData:partialData encoding:CFStringConvertEncodingToNSStringEncoding(encoding)];

		if (partialString) {
			NSAttributedString *partialAttribString = [[NSAttributedString alloc] initWithString:partialString attributes:attrs];

			[aStr appendAttributedString:partialAttribString];

			[partialAttribString release];
		}

		[partialString release];
		[attrs release];
	}

	return aStr;
}

/*
 * Append styl data for one text run
 */

static void AppendStylRunData(NSMutableData *stylData, NSDictionary *attrs, ScriptCode script)
{
	NSFontManager *fontManager = [NSFontManager sharedFontManager];
	NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];

	NSFont *font = [attrs objectForKey:NSFontAttributeName];
	NSColor *color = [[attrs objectForKey:NSForegroundColorAttributeName] colorUsingColorSpaceName:NSDeviceRGBColorSpace device:nil];
	NSFontTraitMask traits = [fontManager traitsOfFont:font];
	NSNumber *underlineStyle = [attrs objectForKey:NSUnderlineStyleAttributeName];
	NSNumber *strokeWidth = [attrs objectForKey:NSStrokeWidthAttributeName];
	NSShadow *shadow = [attrs objectForKey:NSShadowAttributeName];

	int16_t hostFontID = FontIDFromFontNameAndScript([font familyName], script);

	if (hostFontID == 0) {
		hostFontID = [font isFixedPitch] ? 4 /* Monaco */ : 1 /* Application font */;
	}

	int16_t height = CFSwapInt16HostToBig((int16_t)rint([layoutManager defaultLineHeightForFont:font]));
	int16_t ascent = CFSwapInt16HostToBig((int16_t)rint([font ascender]));
	int16_t fontID = CFSwapInt16HostToBig(hostFontID);
	uint8_t face = 0;
	int16_t size = CFSwapInt16HostToBig((int16_t)rint([font pointSize]));
	uint16_t red = CFSwapInt16HostToBig((int16_t)rint([color redComponent] * 65535.0));
	uint16_t green = CFSwapInt16HostToBig((int16_t)rint([color greenComponent] * 65535.0));
	uint16_t blue = CFSwapInt16HostToBig((int16_t)rint([color blueComponent] * 65535.0));

	if (traits & NSBoldFontMask) {
		face |= FONT_FACE_BOLD;
	}

	if (traits & NSItalicFontMask) {
		face |= FONT_FACE_ITALIC;
	}

	if (traits & NSCondensedFontMask) {
		face |= FONT_FACE_CONDENSED;
	}

	if (traits & NSExpandedFontMask) {
		face |= FONT_FACE_EXTENDED;
	}

	if (underlineStyle && [underlineStyle integerValue] != NSUnderlineStyleNone) {
		face |= FONT_FACE_UNDERLINE;
	}

	if (strokeWidth && [strokeWidth doubleValue] > 0.0) {
		face |= FONT_FACE_OUTLINE;
	}

	if (shadow) {
		face |= FONT_FACE_SHADOW;
	}

	[stylData appendBytes:&height length:2];
	[stylData appendBytes:&ascent length:2];
	[stylData appendBytes:&fontID length:2];
	[stylData appendBytes:&face length:1];
	[stylData increaseLengthBy:1];
	[stylData appendBytes:&size length:2];
	[stylData appendBytes:&red length:2];
	[stylData appendBytes:&green length:2];
	[stylData appendBytes:&blue length:2];

	[layoutManager release];
}

/*
 * Convert attributed string to TEXT/styl
 */

static NSData *ConvertToMacTEXTAndStyl(NSAttributedString *aStr, NSData **outStylData)
{
	// Limitations imposed by the Mac TextEdit system.
	const NSUInteger charLimit = 32 * 1024;
	const NSUInteger elementLimit = 1601;

	NSUInteger length = [aStr length];

	if (length > charLimit) {
		aStr = [aStr attributedSubstringFromRange:NSMakeRange(0, charLimit)];
	}

	NSArray *runs = nil;

	NSData *textData = ConvertToMacTextEncoding(aStr, &runs);

	NSMutableData *stylData = [NSMutableData dataWithLength:2]; // number of styles to be filled in at the end

	NSUInteger elements = 0;

	for (NSDictionary *eachRun in runs) {
		if (elements >= elementLimit)
			break;

		NSUInteger offset = [[eachRun objectForKey:@"offset"] unsignedIntegerValue];
		ScriptCode script = [[eachRun objectForKey:@"script"] shortValue];
		NSDictionary *attrs = [eachRun objectForKey:@"attributes"];

		int32_t startChar = CFSwapInt32HostToBig((int32_t)offset);
		[stylData appendBytes:&startChar length:4];

		AppendStylRunData(stylData, attrs, script);

		elements++;
	}

	uint16_t bigEndianElements = CFSwapInt16HostToBig((uint16_t)elements);

	[stylData replaceBytesInRange:NSMakeRange(0, 2) withBytes:&bigEndianElements length:2];

	if (outStylData)
		*outStylData = stylData;

	return textData;
}

/*
 * Convert Mac TEXT/styl to RTF
 */

static void WriteMacTEXTAndStylToPasteboard(NSData *textData, NSData *stylData)
{
	NSMutableAttributedString *aStr = [AttributedStringFromMacTEXTAndStyl(textData, stylData) mutableCopy];

	if (!aStr) {
		NSString *string = [[NSString alloc] initWithData:textData encoding:CFStringConvertEncodingToNSStringEncoding(MacDefaultTextEncoding())];

		if (!string)
			return;

		aStr = [[NSMutableAttributedString alloc] initWithString:string attributes:nil];

		[string release];
	}

	// fix line endings
	[[aStr mutableString] replaceOccurrencesOfString:@"\r" withString:@"\n" options:NSLiteralSearch range:NSMakeRange(0, [aStr length])];

	[g_pboard writeObjects:[NSArray arrayWithObject:aStr]];
}

/*
 * Convert RTF to Mac TEXT/styl
 */

static NSData *GetMacTEXTAndStylDataFromPasteboard(NSData **outStylData)
{
	NSMutableAttributedString *aStr;

	NSArray *objs = [g_pboard readObjectsForClasses:[NSArray arrayWithObject:[NSAttributedString class]] options:nil];

	if ([objs count]) {
		aStr = [[objs objectAtIndex:0] mutableCopy];
	} else {
		objs = [g_pboard readObjectsForClasses:[NSArray arrayWithObject:[NSString class]] options:nil];

		if (![objs count])
			return nil;

		aStr = [[NSMutableAttributedString alloc] initWithString:[objs objectAtIndex:0]];
	}

	// fix line endings
	[[aStr mutableString] replaceOccurrencesOfString:@"\n" withString:@"\r" options:NSLiteralSearch range:NSMakeRange(0, [[aStr mutableString] length])];

	NSData *stylData = nil;
	NSData *textData = ConvertToMacTEXTAndStyl(aStr, &stylData);

	[aStr release];

	if (outStylData)
		*outStylData = stylData;

	return textData;
}

/*
 *	Initialization
 */

void ClipInit(void)
{
	g_pboard = [[NSPasteboard generalPasteboard] retain];
	if (!g_pboard) {
		D(bug("could not create Pasteboard\n"));
	}

	macScrap = [[NSMutableDictionary alloc] init];
}


/*
 *	Deinitialization
 */

void ClipExit(void)
{
	[g_pboard release];
	g_pboard = nil;

	[macScrap release];
	macScrap = nil;
}

/*
 * Zero Mac clipboard
 */

static void ZeroMacClipboard()
{
	D(bug("Zeroing Mac clipboard\n"));
	M68kRegisters r;
	static uint8_t proc[] = {
		0x59, 0x8f,					// subq.l	#4,sp
		0xa9, 0xfc,					// ZeroScrap()
		0x58, 0x8f,					// addq.l	#4,sp
		M68K_RTS >> 8, M68K_RTS & 0xff
	};
	r.d[0] = sizeof(proc);
	Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
	uint32_t proc_area = r.a[0];

	if (proc_area) {
		Host2Mac_memcpy(proc_area, proc, sizeof(proc));
		Execute68k(proc_area, &r);

		r.a[0] = proc_area;
		Execute68kTrap(0xa01f, &r); // DisposePtr
	}
}

/*
 * Write data to Mac clipboard
 */

static void WriteDataToMacClipboard(NSData *pbData, uint32_t type)
{
	D(bug("Writing data %s to Mac clipboard with type '%c%c%c%c'\n", [[pbData description] UTF8String],
		  (type >> 24) & 0xff, (type >> 16) & 0xff, (type >> 8) & 0xff, type & 0xff));

	// Allocate space for new scrap in MacOS side
	M68kRegisters r;
	r.d[0] = [pbData length];
	Execute68kTrap(0xa71e, &r);				// NewPtrSysClear()
	uint32_t scrap_area = r.a[0];

	// Get the native clipboard data
	if (scrap_area) {
		uint8_t * const data = Mac2HostAddr(scrap_area);

		memcpy(data, [pbData bytes], [pbData length]);

		// Add new data to clipboard
		static uint8_t proc[] = {
			0x59, 0x8f,					// subq.l	#4,sp
			0x2f, 0x3c, 0, 0, 0, 0,		// move.l	#length,-(sp)
			0x2f, 0x3c, 0, 0, 0, 0,		// move.l	#type,-(sp)
			0x2f, 0x3c, 0, 0, 0, 0,		// move.l	#outbuf,-(sp)
			0xa9, 0xfe,					// PutScrap()
			0x58, 0x8f,					// addq.l	#4,sp
			M68K_RTS >> 8, M68K_RTS & 0xff
		};
		r.d[0] = sizeof(proc);
		Execute68kTrap(0xa71e, &r);		// NewPtrSysClear()
		uint32_t proc_area = r.a[0];

		if (proc_area) {
			Host2Mac_memcpy(proc_area, proc, sizeof(proc));
			WriteMacInt32(proc_area + 4, [pbData length]);
			WriteMacInt32(proc_area + 10, type);
			WriteMacInt32(proc_area + 16, scrap_area);
			we_put_this_data = true;
			Execute68k(proc_area, &r);

			r.a[0] = proc_area;
			Execute68kTrap(0xa01f, &r); // DisposePtr
		}

		r.a[0] = scrap_area;
		Execute68kTrap(0xa01f, &r);			// DisposePtr
	}
}

/*
 *	Mac application reads clipboard
 */

void GetScrap(void **handle, uint32_t type, int32_t offset)
{
	D(bug("GetScrap handle %p, type %4.4s, offset %d\n", handle, (char *)&type, offset));

	AUTORELEASE_POOL {
		NSString *typeStr;

		if (!g_pboard)
			return;

		if (!(typeStr = GetUTIFromFlavor(type)))
			return;

		if (type == TYPE_TEXT || type == TYPE_STYL) {
			NSData *stylData = nil;
			NSData *textData = GetMacTEXTAndStylDataFromPasteboard(&stylData);

			if (textData) {
				ZeroMacClipboard();

				if (stylData)
					WriteDataToMacClipboard(stylData, TYPE_STYL);

				WriteDataToMacClipboard(textData, TYPE_TEXT);

				return;
			}
		}

		NSData *pbData = nil;

		NSArray *objs = [g_pboard readObjectsForClasses:[NSArray arrayWithObject:[NSPasteboardItem class]] options:nil];

		for (NSPasteboardItem *eachItem in objs) {
			NSData *data = [eachItem dataForType:typeStr];

			if ([data length]) {
				pbData = data;
				break;
			}
		}

		if (pbData) {
			ZeroMacClipboard();
			WriteDataToMacClipboard(pbData, type);
		}
	}
}

/*
 * ZeroScrap() is called before a Mac application writes to the clipboard; clears out the previous contents
 */

void ZeroScrap()
{
	D(bug("ZeroScrap\n"));

	we_put_this_data = false;

	// Defer clearing the host pasteboard until the Mac tries to put something on it.
	// This prevents us from clearing the pasteboard when ZeroScrap() is called during startup.
	should_clear = true;
}

/*
 *	Mac application wrote to clipboard
 */

void PutScrap(uint32_t type, void *scrap, int32_t length)
{
	D(bug("PutScrap type %4.4s, data %p, length %ld\n", (char *)&type, scrap, (long)length));

	AUTORELEASE_POOL {
		NSString *typeStr;

		if (!g_pboard)
			return;

		if (!(typeStr = GetUTIFromFlavor(type)))
			return;

		if (we_put_this_data) {
			we_put_this_data = false;
			return;
		}
		if (length <= 0)
			return;

		if (should_clear) {
			[g_pboard clearContents];

			[macScrap removeAllObjects];
			should_clear = false;
		}

		NSData *pbData = [NSData dataWithBytes:scrap length:length];
		if (!pbData)
			return;

		[macScrap setObject:pbData forKey:[NSNumber numberWithInteger:type]];

		if (type == TYPE_TEXT || type == TYPE_STYL) {
			NSData *textData;
			NSData *stylData;

			textData = [macScrap objectForKey:[NSNumber numberWithInteger:TYPE_TEXT]];
			stylData = [macScrap objectForKey:[NSNumber numberWithInteger:TYPE_STYL]];

			if (textData) {
				WriteMacTEXTAndStylToPasteboard(textData, stylData);
			}
		} else if (pbData) {
			NSPasteboardItem *pbItem = [[[NSPasteboardItem alloc] init] autorelease];

			[pbItem setData:pbData forType:typeStr];

			[g_pboard writeObjects:[NSArray arrayWithObject:pbItem]];
		}
	}
}
