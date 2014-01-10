//
//  Cracker.h
//  Clutch
//
//  Created by DilDog on 12/22/13.
//
//

#import <Foundation/Foundation.h>
#import "Application.h"

@interface Cracker : NSObject
{
    NSString *workingDirectory;
    NSMutableArray *headersToStrip;
    NSString *sinfPath;
    NSString *suppPath;
    NSString *supfPath;
}

// Objective-C method declarations
// File system methods
- (BOOL)removeDirectory:(NSString *)dirpath;
- (BOOL)createDirectory:(NSString *)dirpath;
- (BOOL)copyFile:(NSString *)infile toPath:(NSString *)outfile;

// Cracking methods
- (BOOL)crackApplication:(Application *)application; // Cracks the application
- (BOOL)preflightBinaryOfApplication:(Application *)application; // Does some preflight checks on the binary of given application
- (BOOL)crackBinary:(Application *)application; // Cracks the binary
- (BOOL)createWorkingDirectory; // Create the working directory for cracking & sets the path to (NSString *)workingDirectory
- (BOOL)removeTempFiles;

// C method declarations
void get_local_device_information();

// Properties
@property (nonatomic, strong) NSString *workingDirectory;
@property (nonatomic, strong) NSString *sinfPath;
@property (nonatomic, strong) NSString *suppPath;
@property (nonatomic, strong) NSString *supfPath;
@property (nonatomic, strong) NSMutableArray *headersToStrip;

@end
