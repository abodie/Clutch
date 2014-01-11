//
//  Application.m
//  Clutch
//
//  Created by Ninja on 03/01/2014.
//
//

#import "Application.h"

@implementation Application
@synthesize baseDirectory = _baseDirectory, directory = _directory, displayName = _displayName, binary = _binary, UUID = _UUID, version = _version, identifier = _identifier, infoPlist = _infoPlist, baseName = _baseName, binaryPath = _binaryPath; // shutting errors the fuck up


- (NSString *)description
{
    return [NSString stringWithFormat: @"{ Application: BaseDirectory = %@\nDirectory = %@\nDisplayName = %@\nBinary = %@\nBaseName = %@\nUUID = %@\nVersion = %@\nIdentifier = %@\nInfoPlist = %@", baseDirectory, directory, displayName, binary, baseDirectory, UUID, version, identifier, infoPlist];
}

@end
