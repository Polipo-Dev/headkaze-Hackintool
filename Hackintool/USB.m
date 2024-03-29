//
//  USB.m
//  Hackintool
//
//  Created by Ben Baker on 1/29/19.
//  Copyright © 2019 Ben Baker. All rights reserved.
//

#define USB_USEREGISTRY

#include "USB.h"
#include <IOKit/IOMessage.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include "IORegTools.h"
#include "Config.h"
#include "Clover.h"
#include "OpenCore.h"
#include "MiscTools.h"

static NSMutableArray *gDeviceArray = nil;
static CFMutableDictionaryRef gMatchingDict = nil;
static IONotificationPortRef gNotifyPort = nil;
static io_iterator_t gAddedIter = 0;

void usbUnRegisterEvents()
{
	if (gDeviceArray)
	{
		for (NSNumber *privateDataNumber in gDeviceArray)
		{
			MyPrivateData *privateDataRef = (MyPrivateData *)[privateDataNumber unsignedLongLongValue];
			
			destroyPrivateData(privateDataRef);
		}
		
		[gDeviceArray release];
		gDeviceArray = nil;
	}
	
	if (gNotifyPort)
	{
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(gNotifyPort), kCFRunLoopDefaultMode);
		IONotificationPortDestroy(gNotifyPort);
		gNotifyPort = 0;
	}
	
	if (gAddedIter)
	{
		IOObjectRelease(gAddedIter);
		gAddedIter = 0;
	}
	
	if (gMatchingDict)
	{
		//CFRelease(gMatchingDict);
		//CFRelease(gMatchingDict);
		gMatchingDict = nil;
	}
}

void usbRegisterEvents(AppDelegate *appDelegate)
{
	kern_return_t kr;

	usbUnRegisterEvents();
	
	gDeviceArray = [[NSMutableArray alloc] init];
	
	gMatchingDict = IOServiceMatching(kIOUSBDeviceClassName);
	
	//gMatchingDict = (CFMutableDictionaryRef) CFRetain(gMatchingDict); // Needed for kIOTerminatedNotification
	
	if (!gMatchingDict)
		return;
	
	gNotifyPort = IONotificationPortCreate(kIOMasterPortDefault);
	
	CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(gNotifyPort), kCFRunLoopDefaultMode);
	
	kr = IOServiceAddMatchingNotification(gNotifyPort, kIOPublishNotification, gMatchingDict, usbDeviceAdded, appDelegate, &gAddedIter);
	//kr = IOServiceAddMatchingNotification(gNotifyPort, kIOTerminatedNotification, gMatchingDict, usbDeviceRemoved, appDelegate, &gRemovedIter);
	
	usbDeviceAdded(appDelegate, gAddedIter);
	//usbDeviceRemoved(appDelegate, gRemovedIter);
}

void usbDeviceNotification(void *refCon, io_service_t usbDevice, natural_t messageType, void *messageArgument)
{
	MyPrivateData *privateDataRef = (__bridge MyPrivateData *)refCon;
	AppDelegate *appDelegate = (AppDelegate *)privateDataRef->appDelegate;
	
	if (messageType == kIOMessageServiceIsTerminated)
	{
		[appDelegate removeUSBDevice:privateDataRef->locationID name:(__bridge NSString *)privateDataRef->deviceName];
		
		destroyPrivateData(privateDataRef);
		
		[gDeviceArray removeObject:[NSNumber numberWithUnsignedLongLong:(unsigned long long)privateDataRef]];
	}
}

void destroyPrivateData(MyPrivateData *privateDataRef)
{
	kern_return_t kr;
	
	IOObjectRelease(privateDataRef->removedIter);
	
	CFRelease(privateDataRef->deviceName);
	
	if (privateDataRef->deviceInterface)
		kr = (*privateDataRef->deviceInterface)->Release(privateDataRef->deviceInterface);

	NSDeallocateMemoryPages(privateDataRef, sizeof(MyPrivateData));
}

void usbDeviceAdded(void *refCon, io_iterator_t iterator)
{
	kern_return_t kr = KERN_FAILURE;
	io_object_t usbDevice = 0;
	AppDelegate *appDelegate = (__bridge AppDelegate *)refCon;
	
	for (; (usbDevice = IOIteratorNext(iterator)); IOObjectRelease(usbDevice))
	{
		io_name_t deviceName = { };
		IOCFPlugInInterface **plugInInterface = 0;
		IOUSBDeviceInterface650 **deviceInterface = 0;
		//IOUSBDeviceInterface **deviceInterface = 0;
		SInt32 score = 0;
		uint32_t locationID = 0;
		uint8_t devSpeed = -1;
		
		kr = IORegistryEntryGetName(usbDevice, deviceName);
		
		if (kr != KERN_SUCCESS)
			deviceName[0] = '\0';
		
#ifdef USB_USEREGISTRY
		CFMutableDictionaryRef propertyDictionaryRef = 0;
		
		kr = IORegistryEntryCreateCFProperties(usbDevice, &propertyDictionaryRef, kCFAllocatorDefault, kNilOptions);
		
		if (kr == KERN_SUCCESS)
		{
			NSDictionary *propertyDictionary = (__bridge NSDictionary *)propertyDictionaryRef;
			
			locationID = [[propertyDictionary objectForKey:@"locationID"] unsignedIntValue];
			devSpeed = [[propertyDictionary objectForKey:@"Device Speed"] unsignedIntValue];
		}
#else
		kr = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugInInterface, &score);
		
		if ((kr != kIOReturnSuccess) || !plugInInterface)
		{
			NSLog(@"IOCreatePlugInInterfaceForService failed for device '%@' (kr=0x%08x)", [NSString stringWithUTF8String:deviceName], kr);

			continue;
		}

		//kr = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID*) &deviceInterface);
		kr = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID*) &deviceInterface);
		//kr = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID942), (LPVOID*) &deviceInterface);
		
		//(*plugInInterface)->Release(plugInInterface);
		IODestroyPlugInInterface(plugInInterface);
		
		if ((kr != kIOReturnSuccess) || !deviceInterface)
			continue;
		
		kr = (*deviceInterface)->GetLocationID(deviceInterface, &locationID);
		kr = (*deviceInterface)->GetDeviceSpeed(deviceInterface, &devSpeed);
#endif
			
		//MyPrivateData *privateDataRef = (MyPrivateData *)calloc(1, sizeof(MyPrivateData));
		MyPrivateData *privateDataRef = (MyPrivateData *)NSAllocateMemoryPages(sizeof(MyPrivateData));
		
		privateDataRef->deviceName = CFStringCreateWithCString(kCFAllocatorDefault, deviceName, kCFStringEncodingASCII);
		privateDataRef->deviceInterface = deviceInterface;
		privateDataRef->locationID = locationID;
		privateDataRef->appDelegate = appDelegate;
		
		[gDeviceArray addObject:[NSNumber numberWithUnsignedLongLong:(unsigned long long)privateDataRef]];
		
		// NSLog(@"deviceName: %@ locationID: %d devSpeed: %d", privateDataRef->deviceName, locationID, (uint32_t)devSpeed);
		
		[appDelegate addUSBDevice:locationID name:(__bridge NSString *)privateDataRef->deviceName devSpeed:devSpeed];
		
		kr = IOServiceAddInterestNotification(gNotifyPort, usbDevice, kIOGeneralInterest, usbDeviceNotification, privateDataRef, &privateDataRef->removedIter);
	}
}

/* void usbDeviceRemoved(void *refCon, io_iterator_t iterator)
{
	for (io_service_t usbDevice; (usbDevice = IOIteratorNext(iterator)); IOObjectRelease(usbDevice));
} */

NSString *getUSBConnectorType(UsbConnector usbConnector)
{
	switch (usbConnector)
	{
		case TypeA:
		case MiniAB:
			return @"USB2";
		case ExpressCard:
			return @"ExpressCard";
		case USB3StandardA:
		case USB3StandardB:
		case USB3MicroB:
		case USB3MicroAB:
		case USB3PowerB:
			return @"USB3";
		case TypeCUSB2Only:
		case TypeCSSSw:
			return @"TypeC+Sw";
		case TypeCSS:
			return @"TypeC";
		case Internal:
			return @"Internal";
		default:
			return @"Reserved";
	}
}

NSString *getUSBConnectorSpeed(uint8_t speed)
{
	switch (speed)
	{
		case kUSBDeviceSpeedLow:
			return @"1.5 Mbps";
		case kUSBDeviceSpeedFull:
			return @"12 Mbps";
		case kUSBDeviceSpeedHigh:
			return @"480 Mbps";
		case kUSBDeviceSpeedSuper:
			return @"5 Gbps";
		case kUSBDeviceSpeedSuperPlus:
			return @"10 Gbps";
		default:
			return @"Unknown";
	}
}

void injectDefaultUSBPowerProperties(NSMutableDictionary *ioProviderMergePropertiesDictionary)
{
	[ioProviderMergePropertiesDictionary setObject:[NSNumber numberWithInt:2100] forKey:@"kUSBSleepPortCurrentLimit"];
	[ioProviderMergePropertiesDictionary setObject:[NSNumber numberWithInt:5100] forKey:@"kUSBSleepPowerSupply"];
	[ioProviderMergePropertiesDictionary setObject:[NSNumber numberWithInt:2100] forKey:@"kUSBWakePortCurrentLimit"];
	[ioProviderMergePropertiesDictionary setObject:[NSNumber numberWithInt:5100] forKey:@"kUSBWakePowerSupply"];
}

void injectUSBPowerProperties(AppDelegate *appDelegate, NSMutableDictionary *ioProviderMergePropertiesDictionary)
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *ioUSBHostPath = @"/System/Library/Extensions/IOUSBHostFamily.kext/Contents/Info.plist";
	
	if (![fileManager fileExistsAtPath:ioUSBHostPath])
		return;
	
	NSDictionary *ioUSBHostInfoDictionary = [NSDictionary dictionaryWithContentsOfFile:ioUSBHostPath];
	NSDictionary *ioUSBHostIOKitPersonalities = [ioUSBHostInfoDictionary objectForKey:@"IOKitPersonalities"];
	NSString *nearestModelIdentifier = nil;
	
	// If we already have an entry leave it out
	if ([[ioUSBHostIOKitPersonalities allKeys] containsObject:appDelegate.modelIdentifier])
		return;
	
	// Get the closest model and use the power entries for it
	if (![appDelegate tryGetNearestModel:[ioUSBHostIOKitPersonalities allKeys] modelIdentifier:appDelegate.modelIdentifier nearestModelIdentifier:&nearestModelIdentifier])
		return;
	
	//NSLog(@"nearestModelIdentifier: %@", nearestModelIdentifier);
	
	NSDictionary *ioUSBHostIOKitPersonalityDictionary = [ioUSBHostIOKitPersonalities objectForKey:nearestModelIdentifier];
	NSDictionary *ioUSBHostIOProviderMergePropertiesDictionary = [ioUSBHostIOKitPersonalityDictionary objectForKey:@"IOProviderMergeProperties"];
	
	NSNumber *sleepPortCurrentLimit = [ioUSBHostIOProviderMergePropertiesDictionary objectForKey:@"kUSBSleepPortCurrentLimit"];
	NSNumber *sleepPowerSupply = [ioUSBHostIOProviderMergePropertiesDictionary objectForKey:@"kUSBSleepPowerSupply"];
	NSNumber *wakePortCurrentLimit = [ioUSBHostIOProviderMergePropertiesDictionary objectForKey:@"kUSBWakePortCurrentLimit"];
	NSNumber *wakePowerSupply = [ioUSBHostIOProviderMergePropertiesDictionary objectForKey:@"kUSBWakePowerSupply"];
	
	[ioProviderMergePropertiesDictionary setObject:sleepPortCurrentLimit forKey:@"kUSBSleepPortCurrentLimit"];
	[ioProviderMergePropertiesDictionary setObject:sleepPowerSupply forKey:@"kUSBSleepPowerSupply"];
	[ioProviderMergePropertiesDictionary setObject:wakePortCurrentLimit forKey:@"kUSBWakePortCurrentLimit"];
	[ioProviderMergePropertiesDictionary setObject:wakePowerSupply forKey:@"kUSBWakePowerSupply"];
}

void injectUSBControllerProperties(AppDelegate *appDelegate, NSMutableDictionary *ioKitPersonalities, NSNumber *usbControllerID)
{
	// AppleUSBXHCISPT
	// AppleUSBXHCISPT1
	// AppleUSBXHCISPT2
	// AppleUSBXHCISPT3
	// AppleUSBXHCISPT3
	
	// Haswell:
	// AppleUSBXHCILPTHB iMac14,2
	// CFBundleIdentifier		com.apple.driver.usb.AppleUSBXHCIPCI
	// IOClass					AppleUSBXHCILPTHB
	// IOPCIPrimaryMatch		0x8cb18086
	// IOPCIPauseCompatible		YES
	// IOPCITunnelCompatible	YES
	// IOProviderClass			IOPCIDevice
	// IOProbeScore				5000
	//
	// Skylake:
	// AppleUSBXHCISPT1 iMac17,1
	// CFBundleIdentifier		com.apple.driver.usb.AppleUSBXHCIPCI
	// IOClass					AppleUSBXHCISPT1
	// IOPCIPrimaryMatch		0xa12f8086
	// IOPCIPauseCompatible		YES
	// IOPCITunnelCompatible	YES
	// IOProviderClass			IOPCIDevice
	// IOProbeScore				5000
	
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *ioUSBHostPlugInsPath = @"/System/Library/Extensions/IOUSBHostFamily.kext/Contents/PlugIns/AppleUSBXHCIPCI.kext/Contents/Info.plist";
	
	if (![fileManager fileExistsAtPath:ioUSBHostPlugInsPath])
		return;
	
	NSDictionary *ioUSBHostInfoDictionary = [NSDictionary dictionaryWithContentsOfFile:ioUSBHostPlugInsPath];
	NSDictionary *ioUSBHostIOKitPersonalities = [ioUSBHostInfoDictionary objectForKey:@"IOKitPersonalities"];
	NSString *usbControllerIDString = [NSString stringWithFormat:@"0x%08x", [usbControllerID unsignedIntValue]];
	
	for (NSString *key in ioUSBHostIOKitPersonalities.allKeys)
	{
		NSMutableDictionary *ioUSBDictionary = [[[ioUSBHostIOKitPersonalities objectForKey:key] mutableCopy] autorelease];
		NSString *ioPCIPrimaryMatch = [ioUSBDictionary objectForKey:@"IOPCIPrimaryMatch"];
		
		if (ioPCIPrimaryMatch == nil)
			continue;
		
		if ([ioPCIPrimaryMatch rangeOfString:usbControllerIDString options:NSCaseInsensitiveSearch].location == NSNotFound)
			continue;
		
		[ioUSBDictionary setObject:@(5000) forKey:@"IOProbeScore"];
		
		[ioKitPersonalities setObject:ioUSBDictionary forKey:[NSString stringWithFormat:@"%@ %@", key, appDelegate.modelIdentifier]];
	}
}

int checkEC(AppDelegate *appDelegate)
{
	// https://github.com/corpnewt/USBMap/blob/master/USBMap.command
	//
	// Let's look for a couple of things
	// 1. We check for the existence of AppleBusPowerController in ioreg -> IOService
	//    If it exists, then we don't need any SSDT or renames
	// 2. We want to see if we have ECDT in ACPI and if so, we force a fake EC SSDT
	//    as renames and such can interfere
	// 3. We check for EC, EC0, H_EC, or ECDV in ioreg - and if found, we check
	//    if the _STA is 0 or not - if it's not 0, and not EC, we prompt for a rename
	//    We match that against the PNP0C09 name in ioreg
	
	if (hasIORegEntry(@"IOService:/AppleACPIPlatformExpert/EC/AppleBusPowerController"))
		return 4;
	
	// At this point - we know AppleBusPowerController isn't loaded - let's look at renames and such
	// Check for ECDT in ACPI - if this is present, all bets are off
	// and we need to avoid any EC renames and such
	
	if (appDelegate.bootLog != nil)
	{
		NSRange startString = [appDelegate.bootLog rangeOfString:@"GetAcpiTablesList"];
		NSRange endString = [appDelegate.bootLog rangeOfString:@"GetUserSettings"];
		NSRange stringRange = NSMakeRange(startString.location + startString.length, endString.location - startString.location - startString.length);
		NSString *acpiString = [appDelegate.bootLog substringWithRange:stringRange];
		
		if ([acpiString containsString:@"ECDT"])
			return 0;
	}
	
	NSArray *usbACPIArray = @[@"EC", @"EC0", @"H_EC", @"ECDV"];
	
	for (int i = 0; i < [usbACPIArray count]; i++)
	{
		NSMutableDictionary *acpiDictionary = nil;
		
		if (!getIORegProperties([NSString stringWithFormat:@"IOService:/AppleACPIPlatformExpert/%@", [usbACPIArray objectAtIndex:i]], &acpiDictionary))
			continue;
		
		NSData *propertyValue = [acpiDictionary objectForKey:@"name"];
		NSString *name = [NSString stringWithCString:(const char *)[propertyValue bytes] encoding:NSASCIIStringEncoding];
		NSNumber *_sta = [acpiDictionary objectForKey:@"_STA"];
		
		if ([name isEqualToString:@"PNP0C09"] && [_sta unsignedIntValue] == 0)
			return 0;
		
		return i;
	}
	
	// If we got here, then we didn't find EC, and didn't need to rename it
	// so we return 0 to prompt for an EC fake SSDT to be made
	return 0;
}

void validateUSBPower(AppDelegate *appDelegate)
{
	NSBundle *mainBundle = [NSBundle mainBundle];
	NSString *iaslPath = [mainBundle pathForResource:@"iasl" ofType:@"" inDirectory:@"Utilities"];
	NSString *ssdtECPath = [mainBundle pathForResource:@"SSDT-EC" ofType:@"dsl" inDirectory:@"ACPI"];
	NSString *desktopPath = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	NSString *stdoutString = nil;
	
	int retVal = checkEC(appDelegate);
	
	switch(retVal)
	{
		case 0:
			if ([appDelegate showAlert:@"SSDT-EC Required" text:@"Generating SSDT-EC..."])
			{
				launchCommand(iaslPath, @[@"-p", [NSString stringWithFormat:@"%@/SSDT-EC.aml", desktopPath], ssdtECPath], &stdoutString);
				//NSLog(@"%@", stdoutString);
			}
			break;
		case 1:
		{
			if ([appDelegate showAlert:@"Rename Required" text:@"Renaming EC0 to EC..."])
			{
				NSMutableDictionary *configDictionary = nil;
				NSString *configPath = nil;
				
				if (![Config openConfig:appDelegate configDictionary:&configDictionary configPath:&configPath])
					break;
				
				if ([appDelegate isBootloaderOpenCore])
				{
					NSMutableDictionary *acpiDSDTDictionary = [OpenCore createACPIDSDTDictionaryWithFind:@"EC0_" replace:@"EC__"];
					[OpenCore addACPIDSDTPatchWith:configDictionary patchDictionary:acpiDSDTDictionary];
					[configDictionary writeToFile:configPath atomically:YES];
				}
				else
				{
					NSMutableDictionary *acpiDSDTDictionary = [Clover createACPIDSDTDictionaryWithFind:@"EC0_" replace:@"EC__"];
					[Clover addACPIDSDTPatchWith:configDictionary patchDictionary:acpiDSDTDictionary];
					[configDictionary writeToFile:configPath atomically:YES];
				}
			}
			break;
		}
		case 2:
		{
			if ([appDelegate showAlert:@"Rename Required" text:@"Renaming H_EC to EC..."])
			{
				NSMutableDictionary *configDictionary = nil;
				NSString *configPath = nil;
				
				if (![Config openConfig:appDelegate configDictionary:&configDictionary configPath:&configPath])
					break;
				
				if ([appDelegate isBootloaderOpenCore])
				{
					NSMutableDictionary *acpiDSDTDictionary = [OpenCore createACPIDSDTDictionaryWithFind:@"H_EC" replace:@"EC__"];
					[OpenCore addACPIDSDTPatchWith:configDictionary patchDictionary:acpiDSDTDictionary];
					[configDictionary writeToFile:configPath atomically:YES];
				}
				else
				{
					NSMutableDictionary *acpiDSDTDictionary = [Clover createACPIDSDTDictionaryWithFind:@"H_EC" replace:@"EC__"];
					[Clover addACPIDSDTPatchWith:configDictionary patchDictionary:acpiDSDTDictionary];
					[configDictionary writeToFile:configPath atomically:YES];
				}
			}
			break;
		}
		case 3:
		{
			if ([appDelegate showAlert:@"Rename Required" text:@"Renaming ECDV to EC..."])
			{
				NSMutableDictionary *configDictionary = nil;
				NSString *configPath = nil;
				
				if (![Config openConfig:appDelegate configDictionary:&configDictionary configPath:&configPath])
					break;
				
				if ([appDelegate isBootloaderOpenCore])
				{
					NSMutableDictionary *acpiDSDTDictionary = [OpenCore createACPIDSDTDictionaryWithFind:@"ECDV" replace:@"EC__"];
					[OpenCore addACPIDSDTPatchWith:configDictionary patchDictionary:acpiDSDTDictionary];
					[configDictionary writeToFile:configPath atomically:YES];
				}
				else
				{
					NSMutableDictionary *acpiDSDTDictionary = [Clover createACPIDSDTDictionaryWithFind:@"ECDV" replace:@"EC__"];
					[Clover addACPIDSDTPatchWith:configDictionary patchDictionary:acpiDSDTDictionary];
					[configDictionary writeToFile:configPath atomically:YES];
				}
			}
			break;
		}
		case 4:
			NSLog(@"No SSDT-EC Required");
			break;
	}
}

void addUSBDictionary(AppDelegate *appDelegate, NSMutableDictionary *ioKitPersonalities)
{
	NSMutableDictionary *maxPortDictionary = [NSMutableDictionary dictionary];
	bool hasInjectedUSBPowerProperties = NO;
	
	for (NSMutableDictionary *usbEntryDictionary in appDelegate.usbPortsArray)
	{
		NSMutableDictionary *newUSBEntryDictionary = [[usbEntryDictionary mutableCopy] autorelease];
		NSString *name = [usbEntryDictionary objectForKey:@"name"];
		NSString *usbController = [usbEntryDictionary objectForKey:@"UsbController"];
		NSNumber *usbControllerID = [usbEntryDictionary objectForKey:@"UsbControllerID"];
		
		if (usbController == nil || usbControllerID == nil)
			continue;
		
		NSData *portData = [usbEntryDictionary objectForKey:@"port"];
		uint32_t port = getUInt32FromData(portData);
		NSString *hubName = [usbEntryDictionary objectForKey:@"HubName"];
		NSNumber *hubLocation = [usbEntryDictionary objectForKey:@"HubLocation"];
		NSString *modelEntryName = [NSString stringWithFormat:@"%@-%@%@", appDelegate.modelIdentifier, usbController, hubName != nil ? @"-internal-hub" : @""];
		NSString *providerClass = hubName != nil ? hubName : [usbController hasPrefix:@"XH"] ? @"AppleUSBXHCIPCI" : @"AppleUSBEHCIPCI"; // IOUSBDevice?
		
		NSMutableDictionary *modelEntryDictionary = [ioKitPersonalities objectForKey:modelEntryName];
		NSMutableDictionary *ioProviderMergePropertiesDictionary = nil;
		NSMutableDictionary *portsDictionary = nil;
		
		if (modelEntryDictionary == nil)
		{
			modelEntryDictionary =  [NSMutableDictionary dictionary];
			ioProviderMergePropertiesDictionary = [NSMutableDictionary dictionary];
			portsDictionary = [NSMutableDictionary dictionary];
			
			[ioKitPersonalities setObject:modelEntryDictionary forKey:modelEntryName];
			[modelEntryDictionary setObject:ioProviderMergePropertiesDictionary forKey:@"IOProviderMergeProperties"];
			[modelEntryDictionary setObject:appDelegate.modelIdentifier forKey:@"model"];
			[ioProviderMergePropertiesDictionary setObject:portsDictionary forKey:@"ports"];
			
			[modelEntryDictionary setObject:@"com.apple.driver.AppleUSBMergeNub" forKey:@"CFBundleIdentifier"];
			[modelEntryDictionary setObject:@"AppleUSBMergeNub" forKey:@"IOClass"];
			[modelEntryDictionary setObject:@(5000) forKey:@"IOProbeScore"];
			
			//[modelEntryDictionary setObject:@"com.apple.driver.AppleUSBHostMergeProperties" forKey:@"CFBundleIdentifier"];
			//[modelEntryDictionary setObject:@"AppleUSBHostMergeProperties" forKey:@"IOClass"];
			
			//if (hubName != nil)
			[modelEntryDictionary setObject:usbController forKey:@"IONameMatch"];
			
			[modelEntryDictionary setObject:providerClass forKey:@"IOProviderClass"];
			
			[modelEntryDictionary setObject:usbController forKey:@"UsbController"];
			[modelEntryDictionary setObject:usbControllerID forKey:@"UsbControllerID"];
			
			//injectUSBControllerProperties(appDelegate, ioKitPersonalities, usbControllerID);
		}
		else
		{
			ioProviderMergePropertiesDictionary = [modelEntryDictionary objectForKey:@"IOProviderMergeProperties"];
			portsDictionary = [ioProviderMergePropertiesDictionary objectForKey:@"ports"];
		}
		
		if (!hasInjectedUSBPowerProperties)
		{
			injectUSBPowerProperties(appDelegate, ioProviderMergePropertiesDictionary);
			
			hasInjectedUSBPowerProperties = YES;
		}
		
		uint32_t maxPort = [maxPortDictionary[modelEntryName] unsignedIntValue];
		maxPort = MAX(maxPort, port);
		
		maxPortDictionary[modelEntryName] = [NSNumber numberWithInt:maxPort];
		
		if (hubName != nil)
		{
			[modelEntryDictionary setObject:hubLocation forKey:@"locationID"];
			[modelEntryDictionary setObject:[NSNumber numberWithInt:5000] forKey:@"IOProbeScore"];
		}
		
		NSData *maxPortData = [NSData dataWithBytes:&maxPort length:sizeof(maxPort)];
		
		[ioProviderMergePropertiesDictionary setObject:maxPortData forKey:@"port-count"];
		
		[portsDictionary setObject:newUSBEntryDictionary forKey:name];
	}
}

void exportUSBPowerSSDT(AppDelegate *appDelegate, NSMutableDictionary *ioProviderMergePropertiesDictionary)
{
	NSMutableString *ssdtUSBXString = [NSMutableString string];
	
	NSNumber *sleepPortCurrentLimit = [ioProviderMergePropertiesDictionary objectForKey:@"kUSBSleepPortCurrentLimit"];
	NSNumber *sleepPowerSupply = [ioProviderMergePropertiesDictionary objectForKey:@"kUSBSleepPowerSupply"];
	NSNumber *wakePortCurrentLimit = [ioProviderMergePropertiesDictionary objectForKey:@"kUSBWakePortCurrentLimit"];
	NSNumber *wakePowerSupply = [ioProviderMergePropertiesDictionary objectForKey:@"kUSBWakePowerSupply"];
	
	if (sleepPortCurrentLimit == nil || sleepPowerSupply == nil || wakePortCurrentLimit == nil || wakePowerSupply == nil)
		return;
	
	[ssdtUSBXString appendString:@"DefinitionBlock (\"\", \"SSDT\", 2, \"hack\", \"_USBX\", 0)\n"];
	[ssdtUSBXString appendString:@"{\n"];
	[ssdtUSBXString appendString:@"    Device(_SB.USBX)\n"];
	[ssdtUSBXString appendString:@"    {\n"];
	[ssdtUSBXString appendString:@"        Name(_ADR, 0)\n"];
	[ssdtUSBXString appendString:@"        Method (_DSM, 4)\n"];
	[ssdtUSBXString appendString:@"        {\n"];
	[ssdtUSBXString appendString:@"            If (!Arg2) { Return (Buffer() { 0x03 } ) }\n"];
	[ssdtUSBXString appendString:@"            Return (Package()\n"];
	[ssdtUSBXString appendString:@"            {\n"];
	[ssdtUSBXString appendString:[NSString stringWithFormat:@"                \"kUSBSleepPortCurrentLimit\", %d,\n", [sleepPortCurrentLimit unsignedIntValue]]];
	[ssdtUSBXString appendString:[NSString stringWithFormat:@"                \"kUSBSleepPowerSupply\", %d,\n", [sleepPowerSupply unsignedIntValue]]];
	[ssdtUSBXString appendString:[NSString stringWithFormat:@"                \"kUSBWakePortCurrentLimit\", %d,\n", [wakePortCurrentLimit unsignedIntValue]]];
	[ssdtUSBXString appendString:[NSString stringWithFormat:@"                \"kUSBWakePowerSupply\", %d,\n", [wakePowerSupply unsignedIntValue]]];
	[ssdtUSBXString appendString:@"            })\n"];
	[ssdtUSBXString appendString:@"        }\n"];
	[ssdtUSBXString appendString:@"    }\n"];
	[ssdtUSBXString appendString:@"}\n"];

	NSBundle *mainBundle = [NSBundle mainBundle];
	NSString *iaslPath = [mainBundle pathForResource:@"iasl" ofType:@"" inDirectory:@"Utilities"];
	NSString *desktopPath = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	NSString *tempPath = getTempPath();
	NSString *tempFilePath = [NSString stringWithFormat:@"%@/SSDT-USBX.dsl", tempPath];
	NSString *outputFilePath = [NSString stringWithFormat:@"%@/SSDT-USBX.aml", desktopPath];
	NSString *stdoutString = nil;
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:tempFilePath])
		[[NSFileManager defaultManager] removeItemAtPath:tempFilePath error:nil];
	
	NSError *error;
	
	[ssdtUSBXString writeToFile:tempFilePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
	
	launchCommand(iaslPath, @[@"-p", outputFilePath, tempFilePath], &stdoutString);
	//NSLog(@"%@", stdoutString);
	
	NSArray *fileURLs = [NSArray arrayWithObjects:[NSURL fileURLWithPath:outputFilePath], nil];
	[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:fileURLs];
}

void exportUSBPortsKext(AppDelegate *appDelegate)
{
	// XHC
	//	IONameMatch: XHC
	//	IOProviderClass: AppleUSBXHCIPCI
	//	CFBundleIdentifier: com.apple.driver.AppleUSBHostMergeProperties
	//	# kConfigurationName: XHC
	//	# kIsXHC: True
	// EH01
	//	IONameMatch: EH01
	//	IOProviderClass: AppleUSBEHCIPCI
	//	CFBundleIdentifier: com.apple.driver.AppleUSBHostMergeProperties
	//	# kConfigurationName: EH01
	// EH02
	//	IONameMatch: EH02
	//	IOProviderClass: AppleUSBEHCIPCI
	//	CFBundleIdentifier: com.apple.driver.AppleUSBHostMergeProperties
	//	# kConfigurationName: EH02
	
	NSMutableDictionary *infoDictionary = [NSMutableDictionary dictionary];
	NSMutableDictionary *ioKitPersonalities = [NSMutableDictionary dictionary];
	
	[infoDictionary setObject:@"English" forKey:@"CFBundleDevelopmentRegion"];
	[infoDictionary setObject:@"1.0 Copyright © 2018 Headsoft. All rights reserved." forKey:@"CFBundleGetInfoString"];
	[infoDictionary setObject:@"com.Headsoft.USBPorts" forKey:@"CFBundleIdentifier"];
	[infoDictionary setObject:@"6.0" forKey:@"CFBundleInfoDictionaryVersion"];
	[infoDictionary setObject:@"USBPorts" forKey:@"CFBundleName"];
	[infoDictionary setObject:@"KEXT" forKey:@"CFBundlePackageType"];
	[infoDictionary setObject:@"1.0" forKey:@"CFBundleShortVersionString"];
	[infoDictionary setObject:@"????" forKey:@"CFBundleSignature"];
	[infoDictionary setObject:@"1.0" forKey:@"CFBundleVersion"];
	[infoDictionary setObject:@"Root" forKey:@"OSBundleRequired"];
	
	[infoDictionary setObject:ioKitPersonalities forKey:@"IOKitPersonalities"];
	
	addUSBDictionary(appDelegate, ioKitPersonalities);
	
	for (NSString *ioKitKey in [ioKitPersonalities allKeys])
	{
		NSMutableDictionary *modelEntryDictionary = [ioKitPersonalities objectForKey:ioKitKey];
		NSMutableDictionary *ioProviderMergePropertiesDictionary = [modelEntryDictionary objectForKey:@"IOProviderMergeProperties"];
		NSMutableDictionary *portsDictionary = [ioProviderMergePropertiesDictionary objectForKey:@"ports"];
		
		[modelEntryDictionary removeObjectForKey:@"UsbController"];
		[modelEntryDictionary removeObjectForKey:@"UsbControllerID"];

		for (NSString *portKey in [portsDictionary allKeys])
		{
			NSMutableDictionary *usbEntryDictionary = [portsDictionary objectForKey:portKey];
			
			[usbEntryDictionary removeObjectForKey:@"name"];
			[usbEntryDictionary removeObjectForKey:@"locationID"];
			[usbEntryDictionary removeObjectForKey:@"Device"];
			[usbEntryDictionary removeObjectForKey:@"IsActive"];
			[usbEntryDictionary removeObjectForKey:@"UsbController"];
			[usbEntryDictionary removeObjectForKey:@"UsbControllerID"];
			[usbEntryDictionary removeObjectForKey:@"HubName"];
			[usbEntryDictionary removeObjectForKey:@"HubLocation"];
		}
	}
	
	NSString *desktopPath = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	NSString *destFilePath = [NSString stringWithFormat:@"%@/USBPorts.kext", desktopPath];
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:destFilePath])
		[[NSFileManager defaultManager] removeItemAtPath:destFilePath error:nil];
	
	NSError *error;
	
	if(![[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithFormat:@"%@/USBPorts.kext/Contents", desktopPath] withIntermediateDirectories:YES attributes:nil error:&error])
		return;
	
	NSString *outputInfoPath = [NSString stringWithFormat:@"%@/USBPorts.kext/Contents/Info.plist", desktopPath];
	[infoDictionary writeToFile:outputInfoPath atomically:YES];
	
	NSArray *fileURLs = [NSArray arrayWithObjects:[NSURL fileURLWithPath:destFilePath], nil];
	[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:fileURLs];
}

void exportUSBPortsSSDT(AppDelegate *appDelegate)
{
	bool hasExportedUSBPowerSSDT = NO;
	NSMutableDictionary *ioKitPersonalities = [NSMutableDictionary dictionary];
	NSMutableString *ssdtUIACString = [NSMutableString string];
	
	addUSBDictionary(appDelegate, ioKitPersonalities);
	
	[ssdtUIACString appendString:@"DefinitionBlock (\"\", \"SSDT\", 2, \"hack\", \"_UIAC\", 0)\n"];
	[ssdtUIACString appendString:@"{\n"];
	[ssdtUIACString appendString:@"    Device(UIAC)\n"];
	[ssdtUIACString appendString:@"    {\n"];
	[ssdtUIACString appendString:@"        Name(_HID, \"UIA00000\")\n"];
	[ssdtUIACString appendString:@"\n"];
	[ssdtUIACString appendString:@"        Name(RMCF, Package()\n"];
	[ssdtUIACString appendString:@"        {\n"];

	for (NSString *ioKitKey in [ioKitPersonalities allKeys])
	{
		NSMutableDictionary *modelEntryDictionary = [ioKitPersonalities objectForKey:ioKitKey];
		NSString *usbController = [modelEntryDictionary objectForKey:@"UsbController"];
		
		if (usbController == nil)
			continue;
		
		NSNumber *usbControllerID = [modelEntryDictionary objectForKey:@"UsbControllerID"];
		uint32_t deviceID = [usbControllerID unsignedIntValue] & 0xFFFF;
		uint32_t productID = [usbControllerID unsignedIntValue] >> 16;
		NSString *name = [NSString stringWithFormat:@"%04x_%04x", deviceID, productID]; // "8086_a12f", Package()
		NSNumber *locationID = [modelEntryDictionary objectForKey:@"locationID"];
		NSMutableDictionary *ioProviderMergePropertiesDictionary = [modelEntryDictionary objectForKey:@"IOProviderMergeProperties"];
		NSData *portCount = [ioProviderMergePropertiesDictionary objectForKey:@"port-count"];
		NSMutableDictionary *portsDictionary = [ioProviderMergePropertiesDictionary objectForKey:@"ports"];
		
		if (!hasExportedUSBPowerSSDT)
		{
			exportUSBPowerSSDT(appDelegate, ioProviderMergePropertiesDictionary);
			
			hasExportedUSBPowerSSDT = YES;
		}
		
		// EH01, EH02, HUB1, HUB2, XHC
		if (locationID != nil)
		{
			if ([locationID unsignedIntValue] == 0x1D100000)
				name = @"HUB1";
			else if ([locationID unsignedIntValue] == 0x1A100000)
				name = @"HUB2";
		}
		
		[ssdtUIACString appendString:[NSString stringWithFormat:@"            \"%@\", Package()\n", name]];
		[ssdtUIACString appendString:@"            {\n"];
		[ssdtUIACString appendString:[NSString stringWithFormat:@"                \"port-count\", Buffer() { %@ },\n", getByteString(portCount)]];
		[ssdtUIACString appendString:@"                \"ports\", Package()\n"];
		[ssdtUIACString appendString:@"                {\n"];
		
		for (NSString *portKey in [portsDictionary allKeys])
		{
			NSMutableDictionary *usbEntryDictionary = [portsDictionary objectForKey:portKey];
			
			NSNumber *portType = [usbEntryDictionary objectForKey:@"portType"];
			NSNumber *usbConnector = [usbEntryDictionary objectForKey:@"UsbConnector"];
			NSData *port = [usbEntryDictionary objectForKey:@"port"];
			
			[ssdtUIACString appendString:[NSString stringWithFormat:@"                      \"%@\", Package()\n", portKey]];
			[ssdtUIACString appendString:@"                      {\n"];
			if (portType != nil)
				[ssdtUIACString appendString:[NSString stringWithFormat:@"                          \"portType\", %d,\n", [portType unsignedIntValue]]];
			else
				[ssdtUIACString appendString:[NSString stringWithFormat:@"                          \"UsbConnector\", %d,\n", [usbConnector unsignedIntValue]]];
			[ssdtUIACString appendString:[NSString stringWithFormat:@"                          \"port\", Buffer() { %@ },\n", getByteString(port)]];
			[ssdtUIACString appendString:@"                      },\n"];
		}
		
		[ssdtUIACString appendString:@"                },\n"];
		[ssdtUIACString appendString:@"            },\n"];
	}
	
	[ssdtUIACString appendString:@"        })\n"];
	[ssdtUIACString appendString:@"    }\n"];
	[ssdtUIACString appendString:@"}\n"];
	
	NSBundle *mainBundle = [NSBundle mainBundle];
	NSString *iaslPath = [mainBundle pathForResource:@"iasl" ofType:@"" inDirectory:@"Utilities"];
	NSString *desktopPath = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	NSString *tempPath = getTempPath();
	NSString *tempFilePath = [NSString stringWithFormat:@"%@/SSDT-UIAC.dsl", tempPath];
	NSString *outputFilePath = [NSString stringWithFormat:@"%@/SSDT-UIAC.aml", desktopPath];
	NSString *stdoutString = nil;
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:tempFilePath])
		[[NSFileManager defaultManager] removeItemAtPath:tempFilePath error:nil];
	
	NSError *error;

	[ssdtUIACString writeToFile:tempFilePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
	
	launchCommand(iaslPath, @[@"-p", outputFilePath, tempFilePath], &stdoutString);
	//NSLog(@"%@", stdoutString);
	
	NSArray *fileURLs = [NSArray arrayWithObjects:[NSURL fileURLWithPath:outputFilePath], nil];
	[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:fileURLs];
}

void exportUSBPorts(AppDelegate *appDelegate)
{
	validateUSBPower(appDelegate);
	exportUSBPortsKext(appDelegate);
	exportUSBPortsSSDT(appDelegate);
}
