//
//  AVCaptureDevice+USB.swift
//  CameraController
//
//  Created by Itay Brenner on 7/19/20.
//  Copyright © 2020 Itaysoft. All rights reserved.
//

import Foundation
import AVFoundation
import IOKit.usb

extension AVCaptureDevice {

    private func getIOService() throws -> io_service_t {
        var camera: io_service_t = 0
        let cameraInformation = try self.modelID.extractCameraInformation()
        let dictionary: NSMutableDictionary = IOServiceMatching("IOUSBDevice") as NSMutableDictionary
        dictionary["idVendor"] = cameraInformation.vendorId
        dictionary["idProduct"] = cameraInformation.productId

        // adding other keys to this dictionary like kUSBProductString, kUSBVendorString, etc don't
        // seem to have any affect on using IOServiceGetMatchingService to get the correct camera,
        // so we instead get an iterator for the matching services based on idVendor and idProduct
        // and fetch their property dicts and then match against the more specific values

        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iter) == kIOReturnSuccess {
            var cameraCandidate: io_service_t
            cameraCandidate = IOIteratorNext(iter)
            while cameraCandidate != 0 {
                var propsRef: Unmanaged<CFMutableDictionary>?

                if IORegistryEntryCreateCFProperties(
                    cameraCandidate,
                    &propsRef,
                    kCFAllocatorDefault,
                    0) == kIOReturnSuccess {
                    var found: Bool = false
                    if let properties = propsRef?.takeRetainedValue() {

                        // uniqueID starts with hex version of locationID
                        if let locationID = (properties as NSDictionary)["locationID"] as? Int {
                            let locationIDHex = "0x" + String(locationID, radix: 16)
                            if self.uniqueID.hasPrefix(locationIDHex) {
                                camera = cameraCandidate
                                found = true
                            }
                        }
                        if found {
                            // break out of `while (cameraCandidate != 0)`
                            break
                        }
                    }
                }
                cameraCandidate = IOIteratorNext(iter)
            }
        }

        // if we haven't found a camera after looping through the iterator, fallback on GetMatchingService method
        if camera == 0 {
            camera = IOServiceGetMatchingService(kIOMainPortDefault, dictionary)
        }

        return camera
    }

    func usbDevice() throws -> USBDevice {

        let camera = try self.getIOService()
        defer {
            let code: kern_return_t = IOObjectRelease(camera)
            assert( code == kIOReturnSuccess )
        }
        var interfaceRef: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface190>>?
        var configDesc: IOUSBConfigurationDescriptorPtr?
        try camera.ioCreatePluginInterfaceFor(service: kIOUSBDeviceUserClientTypeID) {
            let deviceInterface: DeviceInterfacePointer = try $0.getInterface(uuid: kIOUSBDeviceInterfaceID)
            defer { _ = deviceInterface.pointee.pointee.Release(deviceInterface) }
            let interfaceRequest = IOUSBFindInterfaceRequest(bInterfaceClass: UVCConstants.classVideo,
                                                             bInterfaceSubClass: UVCConstants.subclassVideoControl,
                                                             bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
                                                             bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))
            try deviceInterface.iterate(interfaceRequest: interfaceRequest) {
                interfaceRef = try $0.getInterface(uuid: kIOUSBInterfaceInterfaceID)
            }

            var returnCode: Int32 = 0
            var numConfig: UInt8 = 0
            returnCode = deviceInterface.pointee.pointee.GetNumberOfConfigurations(deviceInterface, &numConfig)
            if returnCode != kIOReturnSuccess {
                print("unable to get number of configurations")
                return
            }

            returnCode = deviceInterface.pointee.pointee.GetConfigurationDescriptorPtr(deviceInterface, 0, &configDesc)
            if returnCode != kIOReturnSuccess {
                print("unable to get config description for config 0 (index)")
                return
            }
        }
        guard interfaceRef != nil else { throw NSError(domain: #function, code: #line, userInfo: nil) }

        let descriptor = configDesc!.proccessDescriptor()

        return USBDevice(interface: interfaceRef.unsafelyUnwrapped,
                         descriptor: descriptor)
    }
}
