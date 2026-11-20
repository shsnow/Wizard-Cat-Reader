// WizardJVMRunner — Apache License 2.0
//
// Native implementations behind app.tachiaz.compat.NativeBridge (the
// Apache-licensed Android-compat surface): bitmaps and canvases on
// CoreGraphics, text on CoreText, JavaScript on JavaScriptCore. PDF
// rendering is intentionally stubbed: Wizard Cat Reader has no local-PDF
// feature yet.
//
// Conventions shared with the Java side (from the Apache shims):
// - Colors are Android ARGB ints; pixel buffers here are premultiplied RGBA.
// - A bitmap crosses JNI as long[]{handle, width, height}.
// - Coordinates are top-left based; the CGContext is flipped once at
//   creation so memory row 0 is the top row and y needs no per-call flip.

#include "WizardInternal.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <JavaScriptCore/JavaScriptCore.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// Provided by the app (strong definition) when a WKWebView bridge exists.
extern "C" char *wizardcat_webkit_command(
    const char *operation,
    long long handle,
    const char *argument1,
    const char *argument2
) __attribute__((weak));

namespace {

// Set once natives are registered: the reverse path WebKit uses to reach
// NativeBridge.dispatchWebKitEvent from threads the VM did not create.
JavaVM *g_vm = nullptr;
jclass g_bridge_class = nullptr;
jmethodID g_dispatch_webkit_event = nullptr;

constexpr const char *kWebKitUnavailable =
    "__UNAVAILABLE__WKWebView bridge is not installed";

struct WizardBitmap {
    size_t width = 0;
    size_t height = 0;
    uint8_t *pixels = nullptr;
    CGContextRef context = nullptr;

    ~WizardBitmap() {
        if (context != nullptr) {
            CGContextRelease(context);
        }
        std::free(pixels);
    }
};

WizardBitmap *bitmap_from(jlong handle) {
    return reinterpret_cast<WizardBitmap *>(handle);
}

size_t pixel_offset(const WizardBitmap *bitmap, jint x, jint y) {
    return (static_cast<size_t>(y) * bitmap->width + static_cast<size_t>(x)) * 4;
}

void throw_runtime(JNIEnv *environment, const char *message) {
    jclass type = environment->FindClass("java/lang/RuntimeException");
    if (type != nullptr) {
        environment->ThrowNew(type, message);
        environment->DeleteLocalRef(type);
    }
}

/// A fresh bitmap with a flipped (top-left origin) drawing context.
WizardBitmap *create_bitmap(size_t width, size_t height) {
    if (width == 0 || height == 0 || width > 32768 || height > 32768) {
        return nullptr;
    }
    size_t stride = width * 4;
    auto *pixels = static_cast<uint8_t *>(std::calloc(height, stride));
    if (pixels == nullptr) {
        return nullptr;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        stride,
        space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(space);
    if (context == nullptr) {
        std::free(pixels);
        return nullptr;
    }
    CGContextTranslateCTM(context, 0, static_cast<CGFloat>(height));
    CGContextScaleCTM(context, 1, -1);
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);

    auto *bitmap = new WizardBitmap();
    bitmap->width = width;
    bitmap->height = height;
    bitmap->pixels = pixels;
    bitmap->context = context;
    return bitmap;
}

jlongArray bitmap_result(JNIEnv *environment, WizardBitmap *bitmap) {
    if (bitmap == nullptr) {
        return nullptr;
    }
    jlongArray result = environment->NewLongArray(3);
    if (result == nullptr) {
        delete bitmap;
        return nullptr;
    }
    jlong values[3] = {
        reinterpret_cast<jlong>(bitmap),
        static_cast<jlong>(bitmap->width),
        static_cast<jlong>(bitmap->height)
    };
    environment->SetLongArrayRegion(result, 0, 3, values);
    return result;
}

/// Draws an image upright inside the flipped context.
void draw_image_upright(
    CGContextRef context,
    CGImageRef image,
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height
) {
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, x, y + height);
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRestoreGState(context);
}

// MARK: Color conversion (Android ARGB <-> premultiplied RGBA bytes)

void write_premultiplied(uint8_t *pixel, jint color) {
    uint32_t value = static_cast<uint32_t>(color);
    uint32_t alpha = (value >> 24) & 0xFF;
    uint32_t red = (value >> 16) & 0xFF;
    uint32_t green = (value >> 8) & 0xFF;
    uint32_t blue = value & 0xFF;
    pixel[0] = static_cast<uint8_t>((red * alpha + 127) / 255);
    pixel[1] = static_cast<uint8_t>((green * alpha + 127) / 255);
    pixel[2] = static_cast<uint8_t>((blue * alpha + 127) / 255);
    pixel[3] = static_cast<uint8_t>(alpha);
}

jint read_premultiplied(const uint8_t *pixel) {
    uint32_t alpha = pixel[3];
    if (alpha == 0) {
        return 0;
    }
    auto unmultiply = [alpha](uint32_t channel) -> uint32_t {
        uint32_t value = (channel * 255 + alpha / 2) / alpha;
        return value > 255 ? 255 : value;
    };
    return static_cast<jint>(
        (alpha << 24) |
        (unmultiply(pixel[0]) << 16) |
        (unmultiply(pixel[1]) << 8) |
        unmultiply(pixel[2])
    );
}

// MARK: Text helpers

CTFontRef create_font(float size, bool bold, JNIEnv *environment, jstring fontName) {
    CTFontRef base = nullptr;
    if (fontName != nullptr) {
        std::string name = wjb_std_string(environment, fontName);
        if (!name.empty()) {
            CFStringRef nameRef = CFStringCreateWithCString(
                kCFAllocatorDefault, name.c_str(), kCFStringEncodingUTF8
            );
            if (nameRef != nullptr) {
                base = CTFontCreateWithName(nameRef, size, nullptr);
                CFRelease(nameRef);
            }
        }
    }
    if (base == nullptr) {
        base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, nullptr);
    }
    if (base != nullptr && bold) {
        CTFontRef emphasized = CTFontCreateCopyWithSymbolicTraits(
            base, size, nullptr, kCTFontTraitBold, kCTFontTraitBold
        );
        if (emphasized != nullptr) {
            CFRelease(base);
            base = emphasized;
        }
    }
    return base;
}

CFAttributedStringRef attributed_text(
    JNIEnv *environment,
    jstring text,
    CTFontRef font,
    CGColorRef color
) {
    jsize length = environment->GetStringLength(text);
    const jchar *characters = environment->GetStringChars(text, nullptr);
    if (characters == nullptr) {
        return nullptr;
    }
    CFStringRef string = CFStringCreateWithCharacters(
        kCFAllocatorDefault,
        reinterpret_cast<const UniChar *>(characters),
        length
    );
    environment->ReleaseStringChars(text, characters);
    if (string == nullptr) {
        return nullptr;
    }

    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFDictionarySetValue(attributes, kCTFontAttributeName, font);
    if (color != nullptr) {
        CFDictionarySetValue(attributes, kCTForegroundColorAttributeName, color);
    }
    CFAttributedStringRef attributed = CFAttributedStringCreate(
        kCFAllocatorDefault, string, attributes
    );
    CFRelease(attributes);
    CFRelease(string);
    return attributed;
}

CGColorRef argb_color(jint color) {
    uint32_t value = static_cast<uint32_t>(color);
    CGFloat components[4] = {
        static_cast<CGFloat>((value >> 16) & 0xFF) / 255,
        static_cast<CGFloat>((value >> 8) & 0xFF) / 255,
        static_cast<CGFloat>(value & 0xFF) / 255,
        static_cast<CGFloat>((value >> 24) & 0xFF) / 255,
    };
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGColorRef result = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return result;
}

jstring java_string_from_js(JNIEnv *environment, JSStringRef value) {
    size_t length = JSStringGetLength(value);
    const JSChar *characters = JSStringGetCharactersPtr(value);
    return environment->NewString(
        reinterpret_cast<const jchar *>(characters),
        static_cast<jsize>(length)
    );
}

// MARK: - Bitmap natives

jlongArray JNICALL bitmap_create(JNIEnv *environment, jclass, jint width, jint height) {
    if (width <= 0 || height <= 0) {
        return nullptr;
    }
    return bitmap_result(
        environment,
        create_bitmap(static_cast<size_t>(width), static_cast<size_t>(height))
    );
}

jlongArray JNICALL bitmap_decode(
    JNIEnv *environment,
    jclass,
    jbyteArray data,
    jint offset,
    jint length
) {
    if (data == nullptr || offset < 0 || length <= 0) {
        return nullptr;
    }
    jbyte *bytes = environment->GetByteArrayElements(data, nullptr);
    if (bytes == nullptr) {
        return nullptr;
    }
    CFDataRef buffer = CFDataCreate(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8 *>(bytes) + offset,
        length
    );
    environment->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
    if (buffer == nullptr) {
        return nullptr;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData(buffer, nullptr);
    CFRelease(buffer);
    if (source == nullptr) {
        return nullptr;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (image == nullptr) {
        return nullptr;
    }

    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    WizardBitmap *bitmap = create_bitmap(width, height);
    if (bitmap == nullptr) {
        CGImageRelease(image);
        return nullptr;
    }
    draw_image_upright(
        bitmap->context, image, 0, 0,
        static_cast<CGFloat>(width), static_cast<CGFloat>(height)
    );
    CGImageRelease(image);
    return bitmap_result(environment, bitmap);
}

jlongArray JNICALL bitmap_crop(
    JNIEnv *environment,
    jclass,
    jlong handle,
    jint x,
    jint y,
    jint width,
    jint height
) {
    WizardBitmap *source = bitmap_from(handle);
    if (source == nullptr || width <= 0 || height <= 0) {
        return nullptr;
    }
    CGImageRef whole = CGBitmapContextCreateImage(source->context);
    if (whole == nullptr) {
        return nullptr;
    }
    CGImageRef part = CGImageCreateWithImageInRect(
        whole, CGRectMake(x, y, width, height)
    );
    CGImageRelease(whole);
    if (part == nullptr) {
        return nullptr;
    }
    WizardBitmap *result = create_bitmap(
        static_cast<size_t>(width), static_cast<size_t>(height)
    );
    if (result == nullptr) {
        CGImageRelease(part);
        return nullptr;
    }
    draw_image_upright(result->context, part, 0, 0, width, height);
    CGImageRelease(part);
    return bitmap_result(environment, result);
}

void JNICALL bitmap_release(JNIEnv *, jclass, jlong handle) {
    delete bitmap_from(handle);
}

jbyteArray JNICALL bitmap_compress(
    JNIEnv *environment,
    jclass,
    jlong handle,
    jint format,
    jint quality
) {
    WizardBitmap *bitmap = bitmap_from(handle);
    if (bitmap == nullptr) {
        return nullptr;
    }
    CGImageRef image = CGBitmapContextCreateImage(bitmap->context);
    if (image == nullptr) {
        return nullptr;
    }

    // Android formats: 0 JPEG, 1 PNG, 2/4 WEBP(lossless) -> PNG, 3 -> JPEG.
    bool lossy = format == 0 || format == 3;
    CFStringRef type = lossy ? CFSTR("public.jpeg") : CFSTR("public.png");

    CFMutableDataRef output = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        output, type, 1, nullptr
    );
    if (destination == nullptr) {
        CFRelease(output);
        CGImageRelease(image);
        return nullptr;
    }
    if (lossy) {
        double value = std::min(100, std::max(0, quality)) / 100.0;
        CFNumberRef number = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberDoubleType, &value
        );
        CFDictionaryRef properties = CFDictionaryCreate(
            kCFAllocatorDefault,
            reinterpret_cast<const void **>(
                const_cast<CFStringRef *>(&kCGImageDestinationLossyCompressionQuality)
            ),
            reinterpret_cast<const void **>(const_cast<CFNumberRef *>(&number)),
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
        CGImageDestinationAddImage(destination, image, properties);
        CFRelease(properties);
        CFRelease(number);
    } else {
        CGImageDestinationAddImage(destination, image, nullptr);
    }
    bool finished = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    if (!finished) {
        CFRelease(output);
        return nullptr;
    }

    CFIndex size = CFDataGetLength(output);
    jbyteArray result = environment->NewByteArray(static_cast<jsize>(size));
    if (result != nullptr) {
        environment->SetByteArrayRegion(
            result, 0, static_cast<jsize>(size),
            reinterpret_cast<const jbyte *>(CFDataGetBytePtr(output))
        );
    }
    CFRelease(output);
    return result;
}

void JNICALL bitmap_erase(JNIEnv *, jclass, jlong handle, jint color) {
    WizardBitmap *bitmap = bitmap_from(handle);
    if (bitmap == nullptr) {
        return;
    }
    size_t count = bitmap->width * bitmap->height;
    if (color == 0) {
        std::memset(bitmap->pixels, 0, count * 4);
        return;
    }
    uint8_t sample[4];
    write_premultiplied(sample, color);
    uint8_t *pixel = bitmap->pixels;
    for (size_t index = 0; index < count; ++index, pixel += 4) {
        std::memcpy(pixel, sample, 4);
    }
}

jint JNICALL bitmap_get_pixel(JNIEnv *, jclass, jlong handle, jint x, jint y) {
    WizardBitmap *bitmap = bitmap_from(handle);
    if (bitmap == nullptr) {
        return 0;
    }
    return read_premultiplied(bitmap->pixels + pixel_offset(bitmap, x, y));
}

void JNICALL bitmap_set_pixel(
    JNIEnv *, jclass, jlong handle, jint x, jint y, jint color
) {
    WizardBitmap *bitmap = bitmap_from(handle);
    if (bitmap == nullptr) {
        return;
    }
    write_premultiplied(bitmap->pixels + pixel_offset(bitmap, x, y), color);
}

void JNICALL bitmap_get_pixels(
    JNIEnv *environment,
    jclass,
    jlong handle,
    jintArray pixels,
    jintArray parameters
) {
    WizardBitmap *bitmap = bitmap_from(handle);
    if (bitmap == nullptr || pixels == nullptr || parameters == nullptr) {
        return;
    }
    jint values[6];
    environment->GetIntArrayRegion(parameters, 0, 6, values);
    jint offset = values[0], stride = values[1];
    jint x = values[2], y = values[3], width = values[4], height = values[5];

    jint *output = environment->GetIntArrayElements(pixels, nullptr);
    if (output == nullptr) {
        return;
    }
    for (jint row = 0; row < height; ++row) {
        const uint8_t *source = bitmap->pixels + pixel_offset(bitmap, x, y + row);
        jint *destination = output + offset + row * stride;
        for (jint column = 0; column < width; ++column) {
            destination[column] = read_premultiplied(source + column * 4);
        }
    }
    environment->ReleaseIntArrayElements(pixels, output, 0);
}

void JNICALL bitmap_set_pixels(
    JNIEnv *environment,
    jclass,
    jlong handle,
    jintArray pixels,
    jintArray parameters
) {
    WizardBitmap *bitmap = bitmap_from(handle);
    if (bitmap == nullptr || pixels == nullptr || parameters == nullptr) {
        return;
    }
    jint values[6];
    environment->GetIntArrayRegion(parameters, 0, 6, values);
    jint offset = values[0], stride = values[1];
    jint x = values[2], y = values[3], width = values[4], height = values[5];

    jint *input = environment->GetIntArrayElements(pixels, nullptr);
    if (input == nullptr) {
        return;
    }
    for (jint row = 0; row < height; ++row) {
        uint8_t *destination = bitmap->pixels + pixel_offset(bitmap, x, y + row);
        const jint *source = input + offset + row * stride;
        for (jint column = 0; column < width; ++column) {
            write_premultiplied(destination + column * 4, source[column]);
        }
    }
    environment->ReleaseIntArrayElements(pixels, input, JNI_ABORT);
}

void JNICALL bitmap_copy_pixels(
    JNIEnv *environment,
    jclass,
    jlong destinationHandle,
    jlong sourceHandle,
    jintArray rectangles
) {
    WizardBitmap *destination = bitmap_from(destinationHandle);
    WizardBitmap *source = bitmap_from(sourceHandle);
    if (destination == nullptr || source == nullptr || rectangles == nullptr) {
        return;
    }
    jint values[8];
    environment->GetIntArrayRegion(rectangles, 0, 8, values);
    jint srcLeft = values[0], srcTop = values[1];
    jint srcRight = values[2], srcBottom = values[3];
    jint dstLeft = values[4], dstTop = values[5];

    jint width = srcRight - srcLeft;
    jint height = srcBottom - srcTop;
    if (width <= 0 || height <= 0) {
        return;
    }
    size_t rowBytes = static_cast<size_t>(width) * 4;
    for (jint row = 0; row < height; ++row) {
        std::memcpy(
            destination->pixels + pixel_offset(destination, dstLeft, dstTop + row),
            source->pixels + pixel_offset(source, srcLeft, srcTop + row),
            rowBytes
        );
    }
}

// MARK: - Canvas natives

void JNICALL canvas_draw_bitmap(
    JNIEnv *environment,
    jclass,
    jlong destinationHandle,
    jlong sourceHandle,
    jintArray rectangles,
    jfloatArray matrix
) {
    WizardBitmap *destination = bitmap_from(destinationHandle);
    WizardBitmap *source = bitmap_from(sourceHandle);
    if (destination == nullptr || source == nullptr ||
        rectangles == nullptr || matrix == nullptr) {
        return;
    }
    jint rects[8];
    jfloat transform[6];
    environment->GetIntArrayRegion(rectangles, 0, 8, rects);
    environment->GetFloatArrayRegion(matrix, 0, 6, transform);

    jint srcWidth = rects[2] - rects[0];
    jint srcHeight = rects[3] - rects[1];
    jint dstWidth = rects[6] - rects[4];
    jint dstHeight = rects[7] - rects[5];
    if (srcWidth <= 0 || srcHeight <= 0 || dstWidth <= 0 || dstHeight <= 0) {
        return;
    }

    CGImageRef whole = CGBitmapContextCreateImage(source->context);
    if (whole == nullptr) {
        return;
    }
    CGImageRef part = CGImageCreateWithImageInRect(
        whole, CGRectMake(rects[0], rects[1], srcWidth, srcHeight)
    );
    CGImageRelease(whole);
    if (part == nullptr) {
        return;
    }

    CGContextRef context = destination->context;
    CGContextSaveGState(context);
    // Android's affine layout (x' = a*x + c*y + tx) matches CGAffineTransform.
    CGContextConcatCTM(context, CGAffineTransformMake(
        transform[0], transform[1], transform[2],
        transform[3], transform[4], transform[5]
    ));
    draw_image_upright(context, part, rects[4], rects[5], dstWidth, dstHeight);
    CGContextRestoreGState(context);
    CGImageRelease(part);
}

void JNICALL canvas_draw_text(
    JNIEnv *environment,
    jclass,
    jlong handle,
    jstring text,
    jintArray style,
    jstring fontName,
    jfloatArray geometry
) {
    WizardBitmap *bitmap = bitmap_from(handle);
    if (bitmap == nullptr || text == nullptr ||
        style == nullptr || geometry == nullptr) {
        return;
    }
    jint styleValues[3];
    jfloat geometryValues[10];
    environment->GetIntArrayRegion(style, 0, 3, styleValues);
    environment->GetFloatArrayRegion(geometry, 0, 10, geometryValues);

    CTFontRef font = create_font(
        geometryValues[2], styleValues[1] != 0, environment, fontName
    );
    if (font == nullptr) {
        return;
    }
    CGColorRef color = argb_color(styleValues[0]);
    CFAttributedStringRef attributed = attributed_text(
        environment, text, font, color
    );
    if (attributed == nullptr) {
        CGColorRelease(color);
        CFRelease(font);
        return;
    }
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    CFRelease(attributed);
    if (line == nullptr) {
        CGColorRelease(color);
        CFRelease(font);
        return;
    }

    CGContextRef context = bitmap->context;
    CGContextSaveGState(context);
    CGContextConcatCTM(context, CGAffineTransformMake(
        geometryValues[4], geometryValues[5], geometryValues[6],
        geometryValues[7], geometryValues[8], geometryValues[9]
    ));
    // Paint.Style ordinals: 0 FILL, 1 STROKE, 2 FILL_AND_STROKE.
    if (styleValues[2] == 1) {
        CGContextSetTextDrawingMode(context, kCGTextStroke);
        CGContextSetLineWidth(context, geometryValues[3]);
        CGContextSetStrokeColorWithColor(context, color);
    } else if (styleValues[2] == 2) {
        CGContextSetTextDrawingMode(context, kCGTextFillStroke);
        CGContextSetLineWidth(context, geometryValues[3]);
        CGContextSetStrokeColorWithColor(context, color);
    } else {
        CGContextSetTextDrawingMode(context, kCGTextFill);
    }
    // Core Text draws y-up; the context is flipped, so mirror the glyphs.
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
    CGContextSetTextPosition(context, geometryValues[0], geometryValues[1]);
    CTLineDraw(line, context);
    CGContextRestoreGState(context);

    CFRelease(line);
    CGColorRelease(color);
    CFRelease(font);
}

// MARK: - Text natives

jstring JNICALL text_register_font(
    JNIEnv *environment,
    jclass,
    jstring path
) {
    if (path == nullptr) {
        return nullptr;
    }
    std::string file = wjb_std_string(environment, path);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8 *>(file.c_str()),
        static_cast<CFIndex>(file.size()),
        false
    );
    if (url == nullptr) {
        return nullptr;
    }
    // Re-registering an already known font is fine; the name still resolves.
    CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, nullptr);

    CGDataProviderRef provider = CGDataProviderCreateWithURL(url);
    CFRelease(url);
    if (provider == nullptr) {
        return nullptr;
    }
    CGFontRef font = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (font == nullptr) {
        return nullptr;
    }
    CFStringRef name = CGFontCopyPostScriptName(font);
    CGFontRelease(font);
    if (name == nullptr) {
        return nullptr;
    }
    char buffer[256];
    jstring result = nullptr;
    if (CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        result = wjb_java_string(environment, buffer);
    }
    CFRelease(name);
    return result;
}

jfloat JNICALL text_measure(
    JNIEnv *environment,
    jclass,
    jstring text,
    jfloat size,
    jboolean bold,
    jstring fontName
) {
    if (text == nullptr) {
        return 0;
    }
    CTFontRef font = create_font(size, bold == JNI_TRUE, environment, fontName);
    if (font == nullptr) {
        return 0;
    }
    CFAttributedStringRef attributed = attributed_text(
        environment, text, font, nullptr
    );
    if (attributed == nullptr) {
        CFRelease(font);
        return 0;
    }
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    CFRelease(attributed);
    jfloat width = 0;
    if (line != nullptr) {
        width = static_cast<jfloat>(
            CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr)
        );
        CFRelease(line);
    }
    CFRelease(font);
    return width;
}

jfloatArray JNICALL text_font_metrics(
    JNIEnv *environment,
    jclass,
    jfloat size,
    jboolean bold,
    jstring fontName
) {
    CTFontRef font = create_font(size, bold == JNI_TRUE, environment, fontName);
    if (font == nullptr) {
        return nullptr;
    }
    jfloat values[3] = {
        static_cast<jfloat>(CTFontGetAscent(font)),
        static_cast<jfloat>(CTFontGetDescent(font)),
        static_cast<jfloat>(CTFontGetLeading(font)),
    };
    CFRelease(font);
    jfloatArray result = environment->NewFloatArray(3);
    if (result != nullptr) {
        environment->SetFloatArrayRegion(result, 0, 3, values);
    }
    return result;
}

jintArray JNICALL text_line_ends(
    JNIEnv *environment,
    jclass,
    jstring text,
    jfloat width,
    jfloat size,
    jboolean bold,
    jstring fontName
) {
    if (text == nullptr) {
        return nullptr;
    }
    jsize length = environment->GetStringLength(text);
    if (length == 0 || width <= 0) {
        return environment->NewIntArray(0);
    }
    CTFontRef font = create_font(size, bold == JNI_TRUE, environment, fontName);
    if (font == nullptr) {
        return nullptr;
    }
    CFAttributedStringRef attributed = attributed_text(
        environment, text, font, nullptr
    );
    CFRelease(font);
    if (attributed == nullptr) {
        return nullptr;
    }
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString(attributed);
    CFRelease(attributed);
    if (typesetter == nullptr) {
        return nullptr;
    }

    std::vector<jint> ends;
    CFIndex start = 0;
    while (start < length) {
        CFIndex count = CTTypesetterSuggestLineBreak(
            typesetter, start, static_cast<double>(width)
        );
        if (count <= 0) {
            ends.push_back(static_cast<jint>(length));
            break;
        }
        start += count;
        ends.push_back(static_cast<jint>(start));
    }
    CFRelease(typesetter);

    jintArray result = environment->NewIntArray(static_cast<jsize>(ends.size()));
    if (result != nullptr && !ends.empty()) {
        environment->SetIntArrayRegion(
            result, 0, static_cast<jsize>(ends.size()), ends.data()
        );
    }
    return result;
}

// MARK: - PDF natives (stubbed: no local-PDF feature in the app)

jlong JNICALL pdf_open(JNIEnv *, jclass, jstring) {
    return 0;
}

jint JNICALL pdf_page_count(JNIEnv *, jclass, jlong) {
    return 0;
}

jintArray JNICALL pdf_page_size(JNIEnv *, jclass, jlong, jint) {
    return nullptr;
}

jboolean JNICALL pdf_render(JNIEnv *, jclass, jlong, jlong, jintArray) {
    return JNI_FALSE;
}

void JNICALL pdf_close(JNIEnv *, jclass, jlong) {
}

// MARK: - JavaScript natives (JavaScriptCore)

jlong JNICALL javascript_create(JNIEnv *, jclass) {
    return reinterpret_cast<jlong>(JSGlobalContextCreate(nullptr));
}

jobject JNICALL javascript_evaluate(
    JNIEnv *environment,
    jclass,
    jlong handle,
    jstring script
) {
    auto context = reinterpret_cast<JSGlobalContextRef>(handle);
    if (context == nullptr || script == nullptr) {
        throw_runtime(environment, "JavaScript context is not available");
        return nullptr;
    }

    jsize length = environment->GetStringLength(script);
    const jchar *characters = environment->GetStringChars(script, nullptr);
    if (characters == nullptr) {
        return nullptr;
    }
    JSStringRef source = JSStringCreateWithCharacters(
        reinterpret_cast<const JSChar *>(characters),
        static_cast<size_t>(length)
    );
    environment->ReleaseStringChars(script, characters);

    JSValueRef exception = nullptr;
    JSValueRef value = JSEvaluateScript(
        context, source, nullptr, nullptr, 0, &exception
    );
    JSStringRelease(source);

    if (exception != nullptr) {
        std::string message = "JavaScript error";
        JSStringRef text = JSValueToStringCopy(context, exception, nullptr);
        if (text != nullptr) {
            size_t size = JSStringGetMaximumUTF8CStringSize(text);
            std::vector<char> buffer(size);
            JSStringGetUTF8CString(text, buffer.data(), size);
            message = buffer.data();
            JSStringRelease(text);
        }
        jclass type = environment->FindClass("app/cash/quickjs/QuickJsException");
        if (type == nullptr) {
            environment->ExceptionClear();
            type = environment->FindClass("java/lang/RuntimeException");
        }
        if (type != nullptr) {
            environment->ThrowNew(type, message.c_str());
            environment->DeleteLocalRef(type);
        }
        return nullptr;
    }

    if (value == nullptr ||
        JSValueIsNull(context, value) ||
        JSValueIsUndefined(context, value)) {
        return nullptr;
    }
    if (JSValueIsBoolean(context, value)) {
        jclass type = environment->FindClass("java/lang/Boolean");
        if (type == nullptr) {
            return nullptr;
        }
        jmethodID of = environment->GetStaticMethodID(
            type, "valueOf", "(Z)Ljava/lang/Boolean;"
        );
        if (of == nullptr) {
            return nullptr;
        }
        return environment->CallStaticObjectMethod(
            type, of, JSValueToBoolean(context, value) ? JNI_TRUE : JNI_FALSE
        );
    }
    if (JSValueIsNumber(context, value)) {
        jclass type = environment->FindClass("java/lang/Double");
        if (type == nullptr) {
            return nullptr;
        }
        jmethodID of = environment->GetStaticMethodID(
            type, "valueOf", "(D)Ljava/lang/Double;"
        );
        if (of == nullptr) {
            return nullptr;
        }
        return environment->CallStaticObjectMethod(
            type, of, JSValueToNumber(context, value, nullptr)
        );
    }
    if (JSValueIsString(context, value)) {
        JSStringRef text = JSValueToStringCopy(context, value, nullptr);
        if (text == nullptr) {
            return nullptr;
        }
        jstring result = java_string_from_js(environment, text);
        JSStringRelease(text);
        return result;
    }
    // Objects and arrays cross as their JSON form, which is what extension
    // scripts that return structures expect to parse.
    JSStringRef json = JSValueCreateJSONString(context, value, 0, nullptr);
    if (json == nullptr) {
        return nullptr;
    }
    jstring result = java_string_from_js(environment, json);
    JSStringRelease(json);
    return result;
}

void JNICALL javascript_close(JNIEnv *, jclass, jlong handle) {
    auto context = reinterpret_cast<JSGlobalContextRef>(handle);
    if (context != nullptr) {
        JSGlobalContextRelease(context);
    }
}

// MARK: - WebKit native

jstring JNICALL webkit_command(
    JNIEnv *environment,
    jclass,
    jstring operation,
    jlong handle,
    jstring argument1,
    jstring argument2
) {
    if (&wizardcat_webkit_command == nullptr) {
        return wjb_java_string(environment, kWebKitUnavailable);
    }
    std::string operationText = wjb_std_string(environment, operation);
    std::string first = wjb_std_string(environment, argument1);
    std::string second = wjb_std_string(environment, argument2);
    char *result = wizardcat_webkit_command(
        operationText.c_str(),
        static_cast<long long>(handle),
        argument1 == nullptr ? nullptr : first.c_str(),
        argument2 == nullptr ? nullptr : second.c_str()
    );
    if (result == nullptr) {
        return nullptr;
    }
    jstring converted = wjb_java_string(environment, result);
    std::free(result);
    return converted;
}

} // namespace

// MARK: - Registration

bool wjb_register_natives(JNIEnv *environment, std::string &error) {
    jclass bridge = environment->FindClass("app/tachiaz/compat/NativeBridge");
    if (bridge == nullptr) {
        environment->ExceptionClear();
        error = "app.tachiaz.compat.NativeBridge is missing from the classpath";
        return false;
    }

    // One entry per line: the CI descriptor test greps `{const_cast<char *>("name"),
    // const_cast<char *>("signature")` pairs and compares them against the Java class.
    static const JNINativeMethod methods[] = {
        {const_cast<char *>("bitmapCreate"), const_cast<char *>("(II)[J"), reinterpret_cast<void *>(&bitmap_create)},
        {const_cast<char *>("bitmapDecode"), const_cast<char *>("([BII)[J"), reinterpret_cast<void *>(&bitmap_decode)},
        {const_cast<char *>("bitmapCrop"), const_cast<char *>("(JIIII)[J"), reinterpret_cast<void *>(&bitmap_crop)},
        {const_cast<char *>("bitmapRelease"), const_cast<char *>("(J)V"), reinterpret_cast<void *>(&bitmap_release)},
        {const_cast<char *>("bitmapCompress"), const_cast<char *>("(JII)[B"), reinterpret_cast<void *>(&bitmap_compress)},
        {const_cast<char *>("bitmapErase"), const_cast<char *>("(JI)V"), reinterpret_cast<void *>(&bitmap_erase)},
        {const_cast<char *>("bitmapGetPixel"), const_cast<char *>("(JII)I"), reinterpret_cast<void *>(&bitmap_get_pixel)},
        {const_cast<char *>("bitmapSetPixel"), const_cast<char *>("(JIII)V"), reinterpret_cast<void *>(&bitmap_set_pixel)},
        {const_cast<char *>("bitmapGetPixels"), const_cast<char *>("(J[I[I)V"), reinterpret_cast<void *>(&bitmap_get_pixels)},
        {const_cast<char *>("bitmapSetPixels"), const_cast<char *>("(J[I[I)V"), reinterpret_cast<void *>(&bitmap_set_pixels)},
        {const_cast<char *>("bitmapCopyPixels"), const_cast<char *>("(JJ[I)V"), reinterpret_cast<void *>(&bitmap_copy_pixels)},
        {const_cast<char *>("canvasDrawBitmap"), const_cast<char *>("(JJ[I[F)V"), reinterpret_cast<void *>(&canvas_draw_bitmap)},
        {const_cast<char *>("canvasDrawText"), const_cast<char *>("(JLjava/lang/String;[ILjava/lang/String;[F)V"), reinterpret_cast<void *>(&canvas_draw_text)},
        {const_cast<char *>("textRegisterFont"), const_cast<char *>("(Ljava/lang/String;)Ljava/lang/String;"), reinterpret_cast<void *>(&text_register_font)},
        {const_cast<char *>("textMeasure"), const_cast<char *>("(Ljava/lang/String;FZLjava/lang/String;)F"), reinterpret_cast<void *>(&text_measure)},
        {const_cast<char *>("textFontMetrics"), const_cast<char *>("(FZLjava/lang/String;)[F"), reinterpret_cast<void *>(&text_font_metrics)},
        {const_cast<char *>("textLineEnds"), const_cast<char *>("(Ljava/lang/String;FFZLjava/lang/String;)[I"), reinterpret_cast<void *>(&text_line_ends)},
        {const_cast<char *>("pdfOpen"), const_cast<char *>("(Ljava/lang/String;)J"), reinterpret_cast<void *>(&pdf_open)},
        {const_cast<char *>("pdfPageCount"), const_cast<char *>("(J)I"), reinterpret_cast<void *>(&pdf_page_count)},
        {const_cast<char *>("pdfPageSize"), const_cast<char *>("(JI)[I"), reinterpret_cast<void *>(&pdf_page_size)},
        {const_cast<char *>("pdfRender"), const_cast<char *>("(JJ[I)Z"), reinterpret_cast<void *>(&pdf_render)},
        {const_cast<char *>("pdfClose"), const_cast<char *>("(J)V"), reinterpret_cast<void *>(&pdf_close)},
        {const_cast<char *>("javascriptCreate"), const_cast<char *>("()J"), reinterpret_cast<void *>(&javascript_create)},
        {const_cast<char *>("javascriptEvaluate"), const_cast<char *>("(JLjava/lang/String;)Ljava/lang/Object;"), reinterpret_cast<void *>(&javascript_evaluate)},
        {const_cast<char *>("javascriptClose"), const_cast<char *>("(J)V"), reinterpret_cast<void *>(&javascript_close)},
        {const_cast<char *>("webkitCommand"), const_cast<char *>("(Ljava/lang/String;JLjava/lang/String;Ljava/lang/String;)Ljava/lang/String;"), reinterpret_cast<void *>(&webkit_command)},
    };

    jint status = environment->RegisterNatives(
        bridge, methods, sizeof(methods) / sizeof(methods[0])
    );
    if (status == JNI_OK && g_bridge_class == nullptr) {
        // Optional: without it the WebView bridge only loses its callbacks.
        environment->GetJavaVM(&g_vm);
        g_dispatch_webkit_event = environment->GetStaticMethodID(
            bridge,
            "dispatchWebKitEvent",
            "(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;"
        );
        if (g_dispatch_webkit_event == nullptr) {
            environment->ExceptionClear();
        } else {
            g_bridge_class = static_cast<jclass>(environment->NewGlobalRef(bridge));
        }
    }
    environment->DeleteLocalRef(bridge);
    if (status != JNI_OK) {
        if (environment->ExceptionCheck()) {
            environment->ExceptionClear();
        }
        error = "RegisterNatives failed with code " + std::to_string(status);
        return false;
    }
    return true;
}

// MARK: - WebKit events (Swift -> Java)

extern "C" char *wjb_webkit_dispatch_event(
    long long handle,
    const char *event,
    const char *argument1,
    const char *argument2
) {
    if (g_vm == nullptr || g_bridge_class == nullptr || g_dispatch_webkit_event == nullptr) {
        return nullptr;
    }
    JNIEnv *environment = nullptr;
    bool attached = false;
    jint status = g_vm->GetEnv(reinterpret_cast<void **>(&environment), JNI_VERSION_1_8);
    if (status == JNI_EDETACHED) {
        JavaVMAttachArgs arguments{JNI_VERSION_1_8, const_cast<char *>("wizard-webkit"), nullptr};
        if (g_vm->AttachCurrentThread(reinterpret_cast<void **>(&environment), &arguments) != JNI_OK) {
            return nullptr;
        }
        attached = true;
    } else if (status != JNI_OK) {
        return nullptr;
    }

    char *output = nullptr;
    if (environment->PushLocalFrame(8) == JNI_OK) {
        jstring eventText = wjb_java_string(environment, event == nullptr ? "" : event);
        jstring first = argument1 == nullptr ? nullptr : wjb_java_string(environment, argument1);
        jstring second = argument2 == nullptr ? nullptr : wjb_java_string(environment, argument2);
        auto result = static_cast<jstring>(environment->CallStaticObjectMethod(
            g_bridge_class,
            g_dispatch_webkit_event,
            static_cast<jlong>(handle),
            eventText,
            first,
            second
        ));
        if (environment->ExceptionCheck()) {
            environment->ExceptionClear();
            output = strdup("__ERROR__Java exception in WebKit callback");
        } else if (result != nullptr) {
            output = strdup(wjb_std_string(environment, result).c_str());
        }
        environment->PopLocalFrame(nullptr);
    } else {
        environment->ExceptionClear();
    }
    // GCD threads are reused for unrelated work: never leave them attached.
    if (attached) {
        g_vm->DetachCurrentThread();
    }
    return output;
}
