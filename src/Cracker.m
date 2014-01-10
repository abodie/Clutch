//
//  Cracker.m
//  Clutch
//
//  Created by DilDog on 12/22/13.
//
//

/*
 * Includes
 */
#import "Cracker.h"
#import "Application.h"
#import "out.h"
#import "dump.h"


#import <utime.h>

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <mach-o/arch.h>
#include <mach/mach.h>

//#define FAT_CIGAM 0xbebafeca
//#define MH_MAGIC 0xfeedface

#define ARMV7 9
#define ARMV7S 11
#define ARM64 16777228

#define ARMV7_SUBTYPE 0x9000000
#define ARMV7S_SUBTYPE 0xb000000
#define ARM64_SUBTYPE 0x1000000

#define CPUTYPE_32 0xc000000
#define CPUTYPE_64 0xc000001

char header_buffer[4096];
uint32_t local_cputype;
uint32_t local_cpusubtype;
int overdrive_enabled;

@implementation Cracker
@synthesize workingDirectory = _workingDirectory;
@synthesize headersToStrip = _headersToStrip;
@synthesize sinfPath = _sinfPath;
@synthesize suppPath = _suppPath;
@synthesize supfPath = _supfPath; // I thought the whole point was that the compiler did this shit for you these days

- (id)init
{
    self = [super init];
    if (self)
    {
        get_local_device_information();
    }
    return self;
}

-(void)dealloc
{
    if (workingDirectory)
    {
        [workingDirectory release];
    }
    
    if (headersToStrip)
    {
        [headersToStrip release];
    }
    
    if (sinfPath)
    {
        [sinfPath release];
    }
    
    if (suppPath)
    {
        [suppPath release];
    }
    
    if (supfPath)
    {
        [supfPath release];
    }
    
    [super dealloc];
}

void get_local_device_information()
{
    host_basic_info_data_t hostinfo;
    mach_msg_type_number_t infocount;
    
    infocount = HOST_BASIC_INFO_COUNT;
    host_info(mach_host_self(), HOST_BASIC_INFO, (host_info_t)&hostinfo, &infocount);
    
    local_cputype = hostinfo.cpu_type;
    local_cpusubtype = hostinfo.cpu_subtype - 1; // for some reason hostinfo returns cpusubtype + 1
    
    NSLog(@"Local cputype: %u", local_cputype);
    NSLog(@"Local cpusubtype: %u",local_cpusubtype);
}


- (BOOL)removeDirectory:(NSString *)dirpath
{
    NSError *error;
    BOOL isDir;
    NSFileManager *fileManager=[NSFileManager defaultManager];
    if(![fileManager fileExistsAtPath:dirpath isDirectory:&isDir])
    {
        if(![fileManager removeItemAtPath:dirpath error:&error])
        {
            ERROR(@"Failed to force remove directory: %@", dirpath);
            NSLog(@"Error: %@", error.localizedDescription);
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)createDirectory:(NSString *)dirpath
{
    NSError *error;
    BOOL isDir;
    NSFileManager *fileManager= [NSFileManager defaultManager];
    if(![fileManager fileExistsAtPath:dirpath isDirectory:&isDir])
    {
        if(![fileManager removeItemAtPath:dirpath error:&error])
        {
            ERROR(@"Failed to remove item at path: %@", dirpath);
            NSLog(@"Error: %@", error);
            return NO;
        }
    }
    if(![fileManager createDirectoryAtPath:dirpath withIntermediateDirectories:YES attributes:nil error:&error])
    {
        ERROR(@"Failed to create directory at path: %@", dirpath);
        NSLog(@"Error: %@", error);
        return NO;
    }
    
    return YES;
}

- (BOOL)copyFile:(NSString *)infile toPath:(NSString *)outfile
{
    NSError *error;
    NSFileManager *fileManager= [NSFileManager defaultManager];
    if(![fileManager createDirectoryAtPath:[outfile stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL])
    {
        ERROR(@"Failed to create directory at path: %@", [outfile stringByDeletingLastPathComponent]);
        return NO;
    }
    
    if ([fileManager fileExistsAtPath:outfile])
    {
        [fileManager removeItemAtPath:outfile error:nil];
    }

    if(![fileManager copyItemAtPath:infile toPath:outfile error:&error])
    {
        ERROR(@"Failed to copy item: %@ to %@", infile, outfile);
        NSLog(@"Error: %@", error.localizedDescription);
        return NO;
    }
    
    return YES;
}

- (BOOL)preflightBinaryOfApplication:(Application *)application
{
    VERBOSE(@"Performing cracking preflight...");
    
    NSString *binaryPath = application.binaryPath;
    NSString *finalBinaryPath = [workingDirectory stringByAppendingFormat:@"Payload/%@/%@", application.baseName, application.binary];
    
    // We do this to hide that the application was modified incase anyone is watching 🙈
    struct stat binary_stat;
    stat([binaryPath UTF8String], &binary_stat);
    
    time_t binary_stat_atime = binary_stat.st_atime;
    time_t binary_stat_mtime = binary_stat.st_mtime;
    
    if (![self crackBinary:application])
    {
        return NO;
    }
    
    struct utimbuf old_time;
    old_time.actime = binary_stat_atime;
    old_time.modtime = binary_stat_mtime;
    
    utime([binaryPath UTF8String], &old_time);
    utime([finalBinaryPath UTF8String], &old_time);
    
    return YES;
        
}

- (BOOL)crackBinary:(Application *)application
{
    VERBOSE(@"Cracking...");
    
    NSString *finalBinaryPath = [workingDirectory stringByAppendingFormat:@"Payload/%@/%@", application.baseName, application.binary];
    
    if (![self copyFile:application.binaryPath toPath:finalBinaryPath])
    {
        return NO;
    }
    
    // Open streams from both binaries
    FILE *oldBinary, *newBinary;
    oldBinary = fopen([application.binaryPath UTF8String], "r+");
    newBinary = fopen([finalBinaryPath UTF8String], "r+");
    
    // Read the Mach-O header
    fread(&header_buffer, sizeof(header_buffer), 1, oldBinary);
    
    struct fat_header *header = (struct fat_header *)(header_buffer);
    
    if (header->magic == FAT_CIGAM)
    {
        VERBOSE(@"Binary is a fat executable");
        
        struct fat_arch *arch;
        struct fat_arch armv7, armv7s, arm64;
        
        arch = (struct fat_arch *) &header[1];
        
        // Iterate through all archs in binary, detecting portions on the way
        for (int i = 0; i < CFSwapInt32(header->nfat_arch); i++)
        {
            
            if (arch->cputype == CPUTYPE_32)
            {
                NSLog(@"32-bit portion detected: %@", [self getPrettyArchName:arch->cpusubtype]);
                
                switch (arch->cpusubtype)
                {
                    case ARMV7_SUBTYPE:
                    {
                        armv7 = *arch;
                        break;
                    }
                    case ARMV7S_SUBTYPE:
                    {
                        armv7s = *arch;
                        break;
                    }
                    default:
                    {
                        NSLog(@"Unknown 32-bit portion: %@", [self getPrettyArchName:arch->cpusubtype]);
                    }
                }
            }
            else if (arch->cpusubtype == CPUTYPE_64)
            {
                switch (arch->cpusubtype)
                {
                    case ARM64_SUBTYPE:
                    {
                        arm64 = *arch;
                        break;
                    }
                    default:
                    {
                        NSLog(@"Unknown 64-bit portion: %@", [self getPrettyArchName:arch->cpusubtype]);
                        break;
                    }
                }
            }
            
            headersToStrip = [[NSMutableArray alloc] init];
            
            // Apply physical restriction filter
            if ((local_cputype == CPUTYPE_32) && (CFSwapInt32(arch->cpusubtype) > local_cpusubtype))
            {
                NSLog(@"Can't crack arch %u on %u.", arch->cpusubtype, local_cpusubtype);
                [headersToStrip addObject:[NSNumber numberWithUnsignedInt:arch->cpusubtype]];
            }
            else if (arch->cputype == CPUTYPE_64)
            {
                if ((local_cpusubtype == CPUTYPE_64) && (arch->cpusubtype > local_cpusubtype))
                {
                    NSLog(@"Can't crack arch %u on %u.", arch->cpusubtype, local_cpusubtype);
                    [headersToStrip addObject:[NSNumber numberWithUnsignedInt:arch->cpusubtype]];
                }
                else if (local_cpusubtype == CPUTYPE_32)
                {
                    NSLog(@"Can't crack 64-bit arch on this device.");
                    [headersToStrip addObject:[NSNumber numberWithUnsignedInt:arch->cpusubtype]];
                }
            }
            
            arch++;
        }
        
        arch = (struct fat_arch *) &header[1]; // reset arch increment
        
        VERBOSE(@"Attempting to dump architectures...");
        
        // Iterate through architectures and attempt to dump them
        for (int i = 0; i < CFSwapInt32(header->nfat_arch); i++)
        {
            
            // Check if the arch is correct for local_cpusubtype
            // Swap the arch if it's able to be cracked
            NSLog(@"local_cputsubtype: %d", local_cpusubtype);
            NSLog(@"arch subtype: %d", arch->cpusubtype);
            if (local_cpusubtype != arch->cpusubtype)
            {
                // Check if we can crack this arch on this device
                if ([headersToStrip containsObject:[NSNumber numberWithUnsignedInt:arch->cpusubtype]])
                {
                    VERBOSE(@"Cannot crack this architecture on this device.")
                    arch++;
                    
                    continue;
                }
                
                VERBOSE(@"Cracking %@ portion.", [self getPrettyArchName:arch->cpusubtype]);
                
                NSString *archPath = [self swapArchitectureOfApplication:application toArchitecture:arch->cpusubtype];
                
                if (archPath == nil)
                {
                    NSLog(@"Failed to swap architectures.");
                    
                    fclose(newBinary);
                    fclose(oldBinary);
                    
                    [self removeTempFiles];
                    
                    return NO;
                }
                
                FILE *swapped_binary = fopen([archPath UTF8String], "r+");
                
                if (arch->cputype == CPUTYPE_32)
                {
                    NSLog(@"32-bit dumping.");
                    // Crack 32-bit arch
#warning This is the bit that needs to be sorted really :///
//#ifndef __LP64__
                    if (!dump_binary_32(swapped_binary, newBinary, arch->offset, archPath, finalBinaryPath))
                    {
                        stop_bar();
                        ERROR(@"Could not crack architecture.");
                        
                        fclose(newBinary);
                        fclose(oldBinary);
                        
                        [self removeTempFiles];
                        return NO;
                    }
                    else
                    {
                        NSLog(@"Cracked arch: %@", [self getPrettyArchName:arch->cpusubtype]);
                    }
//#endif
                }
                else if (arch->cputype == CPUTYPE_64)
                {
//#ifdef __LP64__
                    if (!dump_binary_64(swapped_binary, newBinary, arch->offset, archPath, finalBinaryPath))
                    {
                        stop_bar();
                        ERROR(@"Could not crack architecture.");
                        
                        fclose(newBinary);
                        fclose(oldBinary);
                        
                        [self removeTempFiles];
                        
                        return NO;
                    }
                    else
                    {
                        NSLog(@"Cracked arch: %@", [self getPrettyArchName:arch->cpusubtype]);
                    }
//#endif

                }
            }
            else
            {
                NSLog(@"No need swap-swap attacks needed.");
                
                if (arch->cpusubtype == CPUTYPE_32)
                {
                    // Crack 32-bit arch
//#ifndef __LP64__
                    if (!dump_binary_32(oldBinary, newBinary, arch->offset, application.binaryPath, finalBinaryPath))
                    {
                        stop_bar();
                        ERROR(@"Could not crack architecture.");
                        
                        fclose(newBinary);
                        fclose(oldBinary);
                        
                        [self removeTempFiles];
                        
                        return NO;
                    }
                    else
                    {
                        NSLog(@"Cracked arch: %@", [self getPrettyArchName:arch->cpusubtype]);
                    }
//#endif
                }
                else if (arch->cpusubtype == CPUTYPE_64)
                {
                    // Crack 64-bit arch
//#ifdef __LP64__
                    if (!dump_binary_64(oldBinary, newBinary, arch->offset, application.binaryPath, finalBinaryPath))
                    {
                        stop_bar();
                        ERROR(@"Could not crack architecture.");
                        
                        fclose(newBinary);
                        fclose(oldBinary);
                        
                        [self removeTempFiles];
                        
                        return NO;
                    }
                    else
                    {
                        NSLog(@"Cracked arch: %@", [self getPrettyArchName:arch->cpusubtype]);
                    }
//#endif
                }
            }
        } // end of for loop
    }
    else
    {
        VERBOSE(@"Binary is a thin exectuable.");
        
        struct mach_header *mach_header = (struct mach_header*)(header_buffer);
        
        NSLog(@"Binary arch: %@", [self getPrettyArchName:mach_header->cpusubtype]);
        
        
    }
        
    // All architectures have been cracked, now we need to strip the headers of architectures we cannot crack on this device
    if ([headersToStrip count] > 0)
    {
        for (int i = 0; i < [headersToStrip count]; i++)
        {
            NSLog(@"Header to strip: %@", headersToStrip[i]);
        }
    }
    
    NSLog(@"End of func: crackBinary:");
    
    return YES;
}

- (NSString *)getPrettyArchName:(uint32_t)cpusubtype
{
    switch (cpusubtype)
    {
        case ARMV7_SUBTYPE:
            return @"armv7";
            break;
        case ARMV7S_SUBTYPE:
            return @"armv7s";
            break;
        case ARM64_SUBTYPE:
            return @"arm64";
            break;
        default:
            return @"unknown";
            break;
    }
    
    return nil;
}

- (BOOL)crackApplication:(Application *)application
{
    // Create our working directory
    if (![self createWorkingDirectory]){
        return NO;
    }
    
    VERBOSE(@"Performing initial anaylsis...");
    
    // We used to open Info.plist here and add 'Apple iPhone OS Application Signing' for 'SignerIdentity' but this
    // is no longer needed (we used to do modifications to the timestamps of Info.plist as people used to check if
    // Info.plist had been tampered with.
    
    BOOL success = [self preflightBinaryOfApplication:application];
    
    if (!success)
    {
        ERROR(@"Failed to crack binary.");
        
        return NO;
    }
    
    return YES;
}

- (NSString *)swapArchitectureOfApplication:(Application *)application toArchitecture:(uint32_t)arch_to_swap_to
{
    char buffer[4096]; // sizeof(fat_header)
    
    if (local_cpusubtype == arch_to_swap_to)
    {
        NSLog(@"Dev logic error. No need to swap to the arch the device runs. Hurr.");
        
        return nil;
    }
    
    NSString *tempSwapBinaryPath = [workingDirectory stringByAppendingFormat:@"%@_lwork", [self getPrettyArchName:arch_to_swap_to]];
    
    if (![self copyFile:application.binaryPath toPath:tempSwapBinaryPath])
    {
        [self removeTempFiles];
        
        return nil;
    }
    
    FILE *swap_binary = fopen([tempSwapBinaryPath UTF8String], "r+");
    
    fseek(swap_binary, 0, SEEK_SET);
    fread(&buffer, sizeof(buffer), 1, swap_binary);
    
    struct fat_header *swap_fat_header = (struct fat_header *)(buffer);
    struct fat_arch *arch = (struct fat_arch *)&swap_fat_header[1];
    
    uint32_t swap_cputype, largest_cpusubtype = 0;
    
    for (int i = 0; i < CFSwapInt32(swap_fat_header->nfat_arch); i++)
    {
        if (arch->cpusubtype == arch_to_swap_to)
        {
            NSLog(@"Found our arch to swap: %@", [self getPrettyArchName:arch->cpusubtype]);
            
            swap_cputype = arch->cputype;
            
            //NSLog(@"swap_cputype: %u (%@)\tArch cputype: %u (%@)", swap_cputype, [self getPrettyArchName:swap_cputype], arch->cputype)
        }
        
        if (arch->cpusubtype > largest_cpusubtype)
        {
            largest_cpusubtype = arch->cpusubtype;
        }
        
        arch++;
    }
    
    NSLog(@"Halfway!");
    
    arch = (struct fat_arch *)&swap_fat_header[1]; // reset arch increment
    
    for (int i = 0; CFSwapInt32(swap_fat_header->nfat_arch); i++)
    {
        NSLog(@"Top of loop");
        if (arch->cpusubtype == largest_cpusubtype)
        {
            if (swap_cputype != arch->cputype)
            {
                //NSLog(@"Swap: %u, Arch:%u", swap_cputype, arch->cputype);
                NSLog(@"cputypes to swap are incompatible.");
                
                return nil;
            }
            
            NSLog(@"Replaced %@'s cpusubtype to %@.", [self getPrettyArchName:arch->cpusubtype], [self getPrettyArchName:arch_to_swap_to]);
            arch->cpusubtype = arch_to_swap_to;
        }
        else if (arch->cpusubtype == arch_to_swap_to)
        {
            NSLog(@"Replaced %@'s subtype to %@.", [self getPrettyArchName:arch->cpusubtype], [self getPrettyArchName:largest_cpusubtype]);
            arch->cpusubtype = largest_cpusubtype;
        }
        
        if (i == CFSwapInt32(swap_fat_header->nfat_arch))
        {
            break;
        }
        else
        {
            arch++; // this causes a segfault by itself lol.
        }
    }
    
    if (![self copySCInfoKeysForApplication:application])
    {
        return nil;
    }

    fseek(swap_binary, 0, SEEK_SET);
    fwrite(buffer, sizeof(buffer), 1, swap_binary);
    fclose(swap_binary);
    
    VERBOSE(@"Swap: Wrote new arch information.");
    
    return tempSwapBinaryPath;
}

- (BOOL)copySCInfoKeysForApplication:(Application *)application
{
    VERBOSE(@"Moving SC_Info keys...");
    
    // Move SC_Info Keys
    NSArray *SCInfoFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithFormat:@"%@SC_Info/", application.directory] error:nil];
    NSLog(@"%@", application.directory);
    NSLog(@"%@", SCInfoFiles);
    
    for (int i = 0; i < [SCInfoFiles count]; i++)
    {
        if ([SCInfoFiles[i] rangeOfString:@".sinf"].location != NSNotFound)
        {
            sinfPath = [application.directory stringByAppendingFormat:@"SC_Info/%@", SCInfoFiles[i]];
            
            if (![self copyFile:sinfPath toPath:[workingDirectory stringByAppendingFormat:@"SC_Info/%@", SCInfoFiles[i]]])
            {
                NSLog(@"Error moving sinf file.");
                
                return NO;
            }
            
            NSLog(@"Sinf: %@", sinfPath);
        }
        else if ([SCInfoFiles[i] rangeOfString:@".supp"].location != NSNotFound)
        {
            suppPath = [application.directory stringByAppendingFormat:@"SC_Info/%@", SCInfoFiles[i]];
            
            if (![self copyFile:suppPath toPath:[workingDirectory stringByAppendingFormat:@"SC_Info/%@", SCInfoFiles[i]]])
            {
                NSLog(@"Error moving supp file.");
                
                return NO;
            }
            
            NSLog(@"Supp: %@", suppPath);
        }
        else if ([SCInfoFiles[i] rangeOfString:@".supf"].location != NSNotFound)
        {
            supfPath = [application.directory stringByAppendingFormat:@"SC_Info/%@", SCInfoFiles[i]];
            
            if (![self copyFile:supfPath toPath:[workingDirectory stringByAppendingFormat:@"SC_Info/%@", SCInfoFiles[i]]])
            {
                NSLog(@"Error moving supf file.");
                
                return NO;
            }
            
            NSLog(@"Supf: %@", supfPath);
        }
    }
    
    return YES;
}

- (BOOL)removeTempFiles
{
    if (![self removeDirectory:workingDirectory])
    {
        ERROR(@"Failed to remove working directory (you'll have to do this manually from /tmp or restart)");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)createWorkingDirectory
{
    VERBOSE(@"Creating working directory...");
    
    workingDirectory = [NSString stringWithFormat:@"/tmp/%@/", [[NSUUID UUID] UUIDString]];
    
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[workingDirectory stringByAppendingString:@"Payload/"] withIntermediateDirectories:YES attributes:@{@"NSFileOwnerAccountName": @"mobbile", @"NSFileGroupOwnerAccountName": @"mobile"} error:NULL])
    {
        ERROR(@"Could not create working directory"); // this shouldn't happen unless you're doing it wrong
        
        return NO;
    }
    
    return YES;
}


@end