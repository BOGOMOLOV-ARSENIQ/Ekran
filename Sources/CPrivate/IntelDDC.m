#include "CPrivate.h"
#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>

static uint32_t EKNumber(CFDictionaryRef dict, CFStringRef key) {
    CFNumberRef number = CFDictionaryGetValue(dict, key);
    uint32_t value = 0;
    if (number && CFGetTypeID(number) == CFNumberGetTypeID()) CFNumberGetValue(number, kCFNumberSInt32Type, &value);
    return value;
}

io_service_t EKIntelFramebufferForDisplay(CGDirectDisplayID display) {
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(IOFRAMEBUFFER_CONFORMSTO), &iterator) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }
    uint32_t vendor = CGDisplayVendorNumber(display), model = CGDisplayModelNumber(display), serial = CGDisplaySerialNumber(display);
    io_service_t framebuffer, found = IO_OBJECT_NULL;
    while (!found && (framebuffer = IOIteratorNext(iterator))) {
        IOItemCount buses = 0;
        io_service_t connect = IODisplayForFramebuffer(framebuffer, kNilOptions);
        if (connect && IOFBGetI2CInterfaceCount(framebuffer, &buses) == KERN_SUCCESS && buses > 0) {
            CFDictionaryRef info = IODisplayCreateInfoDictionary(connect, kIODisplayOnlyPreferredName);
            if (info) {
                if (EKNumber(info, CFSTR(kDisplayVendorID)) == vendor && EKNumber(info, CFSTR(kDisplayProductID)) == model &&
                    EKNumber(info, CFSTR(kDisplaySerialNumber)) == serial) {
                    found = framebuffer;
                }
                CFRelease(info);
            }
        }
        if (connect) IOObjectRelease(connect);
        if (!found) IOObjectRelease(framebuffer);
    }
    IOObjectRelease(iterator);
    return found;
}

bool EKIntelDDCRequest(io_service_t framebuffer, const uint8_t *send, uint32_t sendLength, uint8_t *reply, uint32_t replyLength) {
    IOItemCount buses = 0;
    if (IOFBGetI2CInterfaceCount(framebuffer, &buses) != KERN_SUCCESS) return false;

    for (IOOptionBits bus = 0; bus < buses; bus++) {
        io_service_t interface;
        if (IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) != KERN_SUCCESS) continue;

        IOI2CRequest request = {0};
        request.sendAddress = 0x6E;
        request.sendTransactionType = kIOI2CSimpleTransactionType;
        request.sendBuffer = (vm_address_t)send;
        request.sendBytes = sendLength;
        if (reply && replyLength) {
            request.minReplyDelay = 30 * 1000 * 1000;  // 30 ms
            request.replyAddress = 0x6F;
            request.replySubAddress = 0x51;
            request.replyTransactionType = kIOI2CDDCciReplyTransactionType;
            request.replyBuffer = (vm_address_t)reply;
            request.replyBytes = replyLength;
        } else {
            request.replyTransactionType = kIOI2CNoTransactionType;
        }

        bool ok = false;
        IOI2CConnectRef connect;
        if (IOI2CInterfaceOpen(interface, kNilOptions, &connect) == KERN_SUCCESS) {
            ok = IOI2CSendRequest(connect, kNilOptions, &request) == KERN_SUCCESS && request.result == kIOReturnSuccess;
            IOI2CInterfaceClose(connect, kNilOptions);
        }
        IOObjectRelease(interface);
        if (ok) return true;
    }
    return false;
}

CFDataRef EKIntelCopyEDID(io_service_t framebuffer) {
    io_service_t connect = IODisplayForFramebuffer(framebuffer, kNilOptions);
    if (!connect) return NULL;
    CFDictionaryRef info = IODisplayCreateInfoDictionary(connect, kIODisplayOnlyPreferredName);
    IOObjectRelease(connect);
    if (!info) return NULL;
    CFDataRef edid = CFDictionaryGetValue(info, CFSTR(kIODisplayEDIDKey));
    if (edid && CFGetTypeID(edid) == CFDataGetTypeID()) CFRetain(edid); else edid = NULL;
    CFRelease(info);
    return edid;
}
