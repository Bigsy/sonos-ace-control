#import <Foundation/Foundation.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>

// Reads the cached USB configuration descriptor only; never opens, resets,
// configures, seizes, or writes to the device.
int main(void) {
    @autoreleasepool {
        NSMutableDictionary *matching = CFBridgingRelease(IOServiceMatching("IOUSBHostDevice"));
        matching[@"idVendor"] = @14552;
        matching[@"idProduct"] = @22321;
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)matching);
        if (!service) { puts("Sonos USB device not found."); return 1; }
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        IOReturn status = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);
        if (status || !plugin) { printf("USB plugin error: %08x\n", status); return 1; }
        IOUSBDeviceInterface **device = NULL;
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
        (*plugin)->Release(plugin);
        if (query || !device) { printf("USB interface error: %08x\n", (unsigned)query); return 1; }
        IOUSBConfigurationDescriptorPtr config = NULL;
        status = (*device)->GetConfigurationDescriptorPtr(device, 0, &config);
        if (!status && config) {
            const UInt8 *data = (const UInt8 *)config;
            UInt16 length = CFSwapInt16LittleToHost(config->wTotalLength);
            for (unsigned offset = 0; offset + 2 <= length;) {
                UInt8 count = data[offset];
                if (count < 2 || offset + count > length) break;
                printf("%04x:", offset);
                for (unsigned i = 0; i < count; ++i) printf(" %02x", data[offset + i]);
                puts(""); offset += count;
            }
        } else printf("Configuration descriptor error: %08x\n", status);
        (*device)->Release(device);
        return status ? 1 : 0;
    }
}
