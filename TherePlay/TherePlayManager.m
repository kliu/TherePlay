//  Based on AKAirplayManager by Andy Roth.

#import "TherePlayManager.h"
#import "AsyncSocket.h"

@interface TherePlayManager () <NSNetServiceBrowserDelegate, NSNetServiceDelegate> {
@private
    NSMutableOrderedSet *devices; // ordered b/c consumers may depend on this
}

@property (nonatomic, retain) NSNetServiceBrowser *serviceBrowser;
@property (nonatomic, retain) TherePlayDevice *connectingDevice; // non-nil only while establishing connection

// These are part of my (probably lame) attempt to implement a {will,did}UpdateDevices framework. Devices have a
// one-to-one relationship with services, on which they depend. So first we sort the add/remove list for services,
// and then update devices.
//
// Note that added services are do not "become" devices until they resolve, cf. NSNetServiceDelegate methods.
//
// -therePlayManagerWillUpdateDevices is sent when we first start updating the services (which will ultimately update
//     *devices*).
// -therePlayManagerDidUpdateDevices is sent when changes are complete (for that cycle).
//
// -isUpdatingServices is kind-of a latched OR of is{Adding,Removing}Services. Cf. the property setters for details.
// This is a (probably overengineered) way to make sure a (possibly theoretical) interleaved/overlapped set of
// add/remove calls behave correctly w.r.t. {will,did}Update....

@property (nonatomic) BOOL isAddingServices;
@property (nonatomic) BOOL isRemovingServices;
@property (nonatomic) BOOL isUpdatingServices;
@property (nonatomic, retain) NSMutableSet *servicesToRemove;
@property (nonatomic, retain) NSMutableSet *servicesToAdd;

@end

@implementation TherePlayManager

#pragma mark - lifecycle

- (id)init
{
	if ((self = [super init])) {
		self.autoConnect = NO;

		devices = [[NSMutableOrderedSet alloc] init];
        _servicesToAdd = [[NSMutableSet alloc] init];
        _servicesToRemove = [[NSMutableSet alloc] init];
	}

	return self;
}

- (void)dealloc
{
    if (_connectedDevice) {
        // this will release _connectedDevice
        [self disconnectFromDevice:_connectedDevice];
    }

    _serviceBrowser.delegate = nil;
    [_serviceBrowser stop];
    [_serviceBrowser release];

    [devices release];
	[_servicesToAdd release];
	[_servicesToRemove release];

	[super dealloc];
}

#pragma mark - public Methods

- (void)start
{
    if (_serviceBrowser) {
        NSLog(@"Already searching for AirPlay services");
    } else {
        NSLog(@"Begin searching for AirPlay services");

        _serviceBrowser = [[NSNetServiceBrowser alloc] init];
        _serviceBrowser.delegate = self;
        [_serviceBrowser searchForServicesOfType:@"_airplay._tcp" inDomain:@""];
    }
}

- (void)stop
{
    [_serviceBrowser stop];
    _serviceBrowser.delegate = nil;
    self.serviceBrowser = nil;
}

- (void)connectToDevice:(TherePlayDevice *)device
{
	NSLog(@"Connecting to device : %@:%d", device.hostname, device.port);

    if (_connectingDevice) {
        NSLog(@"Attempted to connect to device %@ while another connection in progress", device);
        return;
    }

    if (_connectedDevice) {
        [self disconnectFromDevice:_connectedDevice];
    }

    // TODO all kinds of possible error states in here

    self.connectingDevice = device;
    device.socket = [[[AsyncSocket alloc] initWithDelegate:self] autorelease];
    [device.socket connectToHost:device.hostname onPort:device.port error:NULL];
}

- (void)disconnectFromDevice:(TherePlayDevice *)device
{
    if (_connectedDevice != device) {
        // TODO: huh?

        NSLog(@"%s passed device %@ != connnected device %@", __PRETTY_FUNCTION__, device, _connectedDevice);
        return;
    }

    [device retain];

    [_connectedDevice sendStop];
    [self setConnectedDevice:nil];
    if ([_delegate respondsToSelector:@selector(therePlayManager:didDisconnectFromDevice:)]) {
        [_delegate therePlayManager:self didDisconnectFromDevice:device];
    }

    [device release];
}

- (NSArray *)devices
{
    return [devices array];
}

#pragma mark - private methods


// TODO: there is a state problem when we are through updating services, but prior to didUpdateDevices, and devices
// start an updating cycle.

- (void)setIsAddingServices:(BOOL)isAddingServices
{
    // same, so nothing has changed
    if (isAddingServices == _isAddingServices) {
        return;
    }

    // has changed
    _isAddingServices = isAddingServices;

    if (_isAddingServices) {
        [self setIsUpdatingServices:YES];
    } else if (!_isRemovingServices) {
        [self setIsUpdatingServices:NO]; // updating only becomes NO when both adding & removing are done
    }
}

- (void)setIsRemovingServices:(BOOL)isRemovingServices
{
    // same, so nothing has changed
    if (isRemovingServices == _isRemovingServices) {
        return;
    }

    // has changed
    _isRemovingServices = isRemovingServices;

    if (_isRemovingServices) {
        [self setIsUpdatingServices:YES];
    } else if (!_isAddingServices) {
        [self setIsUpdatingServices:NO]; // updating only becomes NO when both adding & removing are done
    }
}

- (void)setIsUpdatingServices:(BOOL)isUpdatingServices
{
    // same, so nothing has changed
    if (isUpdatingServices == _isUpdatingServices) {
        return;
    }

    _isUpdatingServices = isUpdatingServices;

    if (_isUpdatingServices) {
        [self sendWillUpdateMessageIfNeeded];
    } else {
        [self triggerDeviceUpdate];
    }
}

- (void)triggerDeviceUpdate
{
    NSLog(@"%@ triggered device update", NSStringFromClass([self class]));

    TherePlayDevice *device = nil;

    for (NSNetService *service in _servicesToRemove) {
        if ([_servicesToAdd containsObject:service]) {
            [_servicesToRemove removeObject:service];
        }

        if ((device = [self existingDeviceForService:service])) {
            NSLog(@"Removing device %@ for service: %@:%d", device, service.hostName, service.port);
            if (_connectedDevice == device) {
                [self disconnectFromDevice:device];
            }

            [devices removeObject:device];
            NSLog(@"Removed device %@ for service: %@:%d", device, service.hostName, service.port);
        }
    }

    [_servicesToRemove removeAllObjects];

    // must kick this off here, since -netServiceDidResolveAddress: will not be called
    if (![_servicesToAdd count] && [_delegate respondsToSelector:@selector(therePlayManagerDidUpdateDevices:)]) {
        [_delegate therePlayManagerDidUpdateDevices:self];
    }

    for (NSNetService *service in _servicesToAdd) {
        // skip services that are already attached to a device
        if ((device = [self existingDeviceForService:service])) {
            NSLog(@"service %@ already attached to device %@", service, device);
        } else {
            [service setDelegate:self];
            [service resolveWithTimeout:20.0];
        }
    }
}

- (void)sendWillUpdateMessageIfNeeded
{
    NSLog(@"%@ will update devices", NSStringFromClass([self class]));
    if ([_delegate respondsToSelector:@selector(therePlayManagerWillUpdateDevices:)]) {
        [_delegate therePlayManagerWillUpdateDevices:self];
    }
}

- (void)sendDidUpdateMessageIfWarranted
{
    if (![_servicesToAdd count]) {
        NSLog(@"%@ did update devices", NSStringFromClass([self class]));
        if ([_delegate respondsToSelector:@selector(therePlayManagerWillUpdateDevices:)]) {
            [_delegate therePlayManagerWillUpdateDevices:self];
        }
    }
}

- (TherePlayDevice *)existingDeviceForService:(NSNetService *)service
{
    for (TherePlayDevice *device in [[devices set] allObjects])
        if ([[device service] isEqual:service]) {
            return device;
        }

    return nil;
}

#pragma mark - NetServiceBrowserDelegate

- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser didNotSearch:(NSDictionary *)errorDict
{
    // TODO: need to deal with this
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser
           didFindService:(NSNetService *)netService
               moreComing:(BOOL)moreComing
{
    NSLog(@"did find %@", netService);
    [self setIsAddingServices:YES];
    [_servicesToAdd addObject:netService];

    if (!moreComing) {
        [self setIsAddingServices:NO];
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)netServiceBrowser
         didRemoveService:(NSNetService *)netService
               moreComing:(BOOL)moreComing
{
    [self setIsRemovingServices:YES];
    [_servicesToRemove addObject:netService];

    if (!moreComing) {
        [self setIsRemovingServices:NO];
    }
}

#pragma mark - NetServiceDelegate

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
	NSLog(@"Resolved service: %@:%d", service.hostName, service.port);

	TherePlayDevice *device = [[[TherePlayDevice alloc] initWithResolvedService:service] autorelease];
    [devices addObject:device];
    [_servicesToAdd removeObject:service];

	if ([_delegate respondsToSelector:@selector(therePlayManager:didFindDevice:)]) {
		[_delegate therePlayManager:self didFindDevice:device];
	}

	if (_autoConnect && !_connectedDevice) {
		[self connectToDevice:device];
	}

    [self sendDidUpdateMessageIfWarranted];
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict
{
    NSLog(@"%s: could not resolve service %@:\n%@", __PRETTY_FUNCTION__, sender, errorDict);
    [_servicesToAdd removeObject:sender];

    [self sendDidUpdateMessageIfWarranted];
}

- (void)netServiceDidStop:(NSNetService *)sender
{
    // TODO: does this correctly handle this?
    if ([[_connectedDevice service] isEqual:sender]) {
        NSLog(@"%s for service %@", __PRETTY_FUNCTION__, sender);
        [self disconnectFromDevice:_connectedDevice];
    }
}

#pragma mark - AsyncSocketDelegate

- (void)onSocket:(AsyncSocket *)socket didConnectToHost:(NSString *)host port:(UInt16)port
{
    if (![[_connectingDevice socket] isEqual:socket]) {
        NSLog(@"Ignoring %s from socket %@; socket does not match _connecting device %@", __PRETTY_FUNCTION__, socket,
              _connectingDevice);

        return;
    }

    _connectingDevice.connected = YES;
    self.connectedDevice = _connectingDevice;
    self.connectingDevice = nil;

	if (_delegate && [_delegate respondsToSelector:@selector(therePlayManager:didConnectToDevice:)]) {
		[self.connectedDevice sendReverse];
		[_delegate therePlayManager:self didConnectToDevice:self.connectedDevice];
	}
}

@end