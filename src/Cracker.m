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
char buffer[4096]; // random use buffer
uint32_t local_cputype;
uint32_t local_cpusubtype;
int overdrive_enabled;

FILE *newBinary;
FILE *oldBinary;

NSString *newBinaryPath;
NSString *oldBinaryPath;

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

- (void)get_local_device_information
{
    local_cputype = [self cputype];
    local_cpusubtype = [self cpusubtype]; // for some reason hostinfo returns cpusubtype + 1
    
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
    newBinaryPath = finalBinaryPath;
    oldBinaryPath = application.binaryPath;
    
    if (![self copyFile:application.binaryPath toPath:finalBinaryPath])
    {
        return NO;
    }
    
    // Open streams from both binaries
    //FILE *oldBinary, *newBinary;
    oldBinary = fopen([application.binaryPath UTF8String], "r+");
    newBinary = fopen([finalBinaryPath UTF8String], "r+");
    
    // Read the Mach-O header
    fread(&header_buffer, sizeof(header_buffer), 1, oldBinary);
    
    struct fat_header *fat_header = (struct fat_header *)(header_buffer);
    
    switch (fat_header->magic)
    {
        case MH_MAGIC_64:
        {
            NSLog(@"64-bit thin binary detected.");
            
            struct mach_header_64 *header_64 = (struct mach_header_64 *)fat_header;
            
            if (local_cputype == CPU_TYPE_ARM)
            {
                ERROR(@"Can't crack 64-bit arch on 32-bit device.");
                
                return NO;
            }
            
            if (header_64->cpusubtype != local_cpusubtype)
            {
                ERROR(@"Can't crack %@ on %@ device.", [self getPrettyArchName:header_64->cpusubtype], [self getPrettyArchName:local_cpusubtype]);
                
                return NO;
            }
            
            if (!dump64bit(oldBinary, oldBinaryPath, newBinary, 0));
            {
                ERROR(@"Failed to dump %@", [self getPrettyArchName:header_64->cpusubtype]);
                
                return NO;
            }
            
            return YES;
            break;
        }
            
        case MH_MAGIC:
        {
            NSLog(@"32-bit thin binary detected.");
            
            struct mach_header *header_32 = (struct mach_header *)fat_header;
            
            if ((!(local_cputype == CPU_TYPE_ARM64)) && (header_32->cpusubtype > local_cpusubtype))
            {
                ERROR(@"Can't crack 32-bit %@ on 32-bit %@ device.", [self getPrettyArchName:header_32->cpusubtype], [self getPrettyArchName:local_cpusubtype]);
                
                return NO;
            }
            
            if (!dump32bit(oldBinary, oldBinaryPath, newBinary, 0));
            {
                ERROR(@"Failed to dump %@", [self getPrettyArchName:header_32->cpusubtype]);
                
                return NO;
            }
            
            return YES;
            break;
        }
            
        case FAT_CIGAM:
        {
            // FAT Binary
            if (CFSwapInt32(fat_header->nfat_arch) == (uint32_t)3)
            {
                NSLog(@"BigBooty Binary detected (armv7, armv7s, arm64).")
            }
            else
            {
                NSLog(@"Fat binary detected.")
            }
            
            struct fat_arch *arch = (struct fat_arch *)&fat_header[1];
            
            BOOL has64 = FALSE;
            NSMutableArray *stripHeaders = [NSMutableArray new];
            
            for (int i = 0; i < CFSwapInt32(fat_header->nfat_arch); i++)
            {
                if (CFSwapInt32(arch->cputype) == CPU_TYPE_ARM64)
                {
                    NSLog(@"64-bit arch detected.")
                    has64 = TRUE;
                    
                    break;
                }
                
                arch++;
            }
            
            arch = (struct fat_arch *)&fat_header[1]; // reset arch iteration
            
            struct fat_arch *compatibleArch;
            
            for (int i = 0; i < CFSwapInt32(fat_header->nfat_arch); i++)
            {
                NSLog(@"Currently cracking %@", [self getPrettyArchName:arch->cpusubtype]);
                
                switch ([self compatibleWith:arch]) {
                    case COMPATIBLE:
                    {
                        NSLog(@"Arch is compatible with device!");
                        
                        if (!dump(oldBinary, newBinary, oldBinaryPath, arch))
                        {
                            ERROR(@"Can't crack unswapped %@ portion of binary.", [self getPrettyArchName:arch->cpusubtype]);
                            return NO;
                        }
                        
                        compatibleArch = arch;
                        break;
                    }
                        
                    case NOT_COMPATIBLE:
                    {
                        ERROR(@"Architecture not compatible with device.");
                        NSValue *archValue = [NSValue value:&arch withObjCType:@encode(struct fat_arch)];
                        
                        [stripHeaders addObject:archValue];
                        
                        break;
                    }
                        
                    case COMPATIBLE_SWAP:
                    {
                        NSLog(@"Arch compatible, but need to swap.");
                        
                        NSString *stripPath;
                        
                        if (has64)
                        {
                            stripPath = [self stripArch:arch->cpusubtype];
                        }
                        else
                        {
                            stripPath = [self swapArch:arch->cpusubtype];
                        }
                        
                        if (stripPath == NULL)
                        {
                            ERROR(@"Error stripped or swapped binary.");
                            
                            return NO;
                        }
                        
                        FILE *stripBinary = fopen([stripPath UTF8String], "r+");
                        
                        if (!dump(stripBinary, newBinary, stripPath, arch))
                        {
                            ERROR(@"Can't crack stripped/swapped %@ portion of binary.", [self getPrettyArchName:arch->cpusubtype]);
                            
                            fclose(newBinary);
                            fclose(oldBinary);
                            
                            [self removeTempFiles];
                            
                            return NO;
                        }
                        
                        // Swap back here
                        [self swapBack:stripPath];
                        compatibleArch = arch;
                        break;
                    }
                }
                
                if ((CFSwapInt32(fat_header->nfat_arch) - [stripHeaders count]) == 1)
                {
                    if (![self lipoBinary:compatibleArch])
                    {
                        ERROR(@"Could not lipo binary.");
                        
                        return NO;
                    }
                    
                    return YES;
                }
                
                arch++;
            }
            
            if ([stripHeaders count] > 0)
            {
                for (NSValue *obj in stripHeaders)
                {
                    struct fat_arch *stripArch;
                    [obj getValue:&stripArch];
                    
                    [self removeArchitecture:stripArch];
                }
            }
            
            break;
        }
    }
    
    return YES;
}

BOOL dump(FILE *origin, FILE *target, NSString *originPath, struct fat_arch *arch)
{
    NSLog(@"%@", oldBinaryPath);
    if (CFSwapInt32(arch->cputype) == CPU_TYPE_ARM64)
    {
        return dump64bit(origin, target, originPath, CFSwapInt32(arch->offset));
    }
    else
    {
        return dump32bit(origin, target, originPath, CFSwapInt32(arch->offset));
    }
}

- (BOOL)lipoBinary:(struct fat_arch *)arch
{
    
#warning rewrite this to include Application *
    
    NSString *lipoPath = [NSString stringWithFormat:@"%@_lipo", newBinaryPath]; //assign new lipo path
    FILE *lipoOut = fopen([lipoPath UTF8String], "w+");
    
    fseek(newBinary, CFSwapInt32(arch->offset), SEEK_SET); // go to the armv6 offset
    
    void *tmp_buffer = malloc(0x1000); // alloc a temp buffer
    
    NSUInteger remaining = CFSwapInt32(arch->size);
    
    while (remaining > 0) {
        if (remaining > 0x1000)
        {
            // move over 0x1000
            fread(tmp_buffer, 0x1000, 1, newBinary);
            fwrite(tmp_buffer, 0x1000, 1, lipoOut);
            
            remaining -= 0x1000;
        }
        else
        {
            // move over remaining and break
            fread(tmp_buffer, remaining, 1, newBinary);
            fwrite(tmp_buffer, remaining, 1, lipoOut);
            
            break;
        }
    }
    
    free(tmp_buffer); // free the buffer
    fclose(lipoOut); // close lipo output stream
    fclose(newBinary); // close new binary stream
    fclose(oldBinary); // close old binary stream
    
    [[NSFileManager defaultManager] removeItemAtPath:newBinaryPath error:NULL]; // remove old file
    [[NSFileManager defaultManager] moveItemAtPath:lipoPath toPath:newBinaryPath error:NULL]; // move the lipo'd binary to final path
    
    chown([newBinaryPath UTF8String], 501, 501); //adjust permissions
    chmod([newBinaryPath UTF8String], 0777); // adjust permission
    
    return YES;
}

- (NSString *)stripArch:(cpu_subtype_t)keep_arch
{
    NSString *baseName = [oldBinaryPath lastPathComponent]; // get the basename (name of the binary)
	NSString *baseDirectory = [NSString stringWithFormat:@"%@/", [oldBinaryPath stringByDeletingLastPathComponent]];
    
    NSLog(@"##### STRIPPING ARCH #####");
    NSString* suffix = [NSString stringWithFormat:@"%@_lwork", [self getPrettyArchName:keep_arch]];
    NSString *lipoPath = [NSString stringWithFormat:@"%@_%@", oldBinaryPath, suffix]; // assign a new lipo path
    
    [[NSFileManager defaultManager] copyItemAtPath:oldBinaryPath toPath:lipoPath error: NULL];
    
    FILE *lipoOut = fopen([lipoPath UTF8String], "r+"); // prepare the file stream
    
    char stripBuffer[4096];
    
    fseek(lipoOut, SEEK_SET, 0);
    fread(&stripBuffer, sizeof(buffer), 1, lipoOut);
    
    struct fat_header* fh = (struct fat_header*) (stripBuffer);
    struct fat_arch* arch = (struct fat_arch *) &fh[1];
    struct fat_arch copy;
    
    BOOL foundarch = FALSE;
    
    fseek(lipoOut, 8, SEEK_SET); //skip nfat_arch and bin_magic
    
    for (int i = 0; i < CFSwapInt32(fh->nfat_arch); i++)
    {
        if (arch->cpusubtype == keep_arch)
        {
            NSLog(@"found arch to keep %u! Storing it", CFSwapInt32(keep_arch));
            
            foundarch = TRUE;
            fread(&copy, sizeof(struct fat_arch), 1, lipoOut);
        }
        else
        {
            fseek(lipoOut, sizeof(struct fat_arch), SEEK_CUR);
        }
        arch++;
    }
    
    if (!foundarch)
    {
        NSLog(@"error: could not find arch to keep!");
        
        int *p = NULL;
        *p = 1;
        
        return false;
    }
    
    fseek(lipoOut, 8, SEEK_SET);
    fwrite(&copy, sizeof(struct fat_arch), 1, lipoOut);
    
    char data[20];
    
    memset(data,'\0',sizeof(data));
    
    for (int i = 0; i < (CFSwapInt32(fh->nfat_arch) - 1); i++)
    {
        NSLog(@"blanking arch! %u", i);
        
        fwrite(data, sizeof(data), 1, lipoOut);
    }
    
    //change nfat_arch
    NSLog(@"changing nfat_arch");
    
    uint32_t bin_nfat_arch = 0x1000000;
    
    NSLog(@"number of architectures %u", CFSwapInt32(bin_nfat_arch));
    
    fseek(lipoOut, 4, SEEK_SET); //bin_magic
    fwrite(&bin_nfat_arch, 4, 1, lipoOut);
    
    NSLog(@"Written new header to binary!");
    
    fclose(lipoOut);
    
    NSLog(@"copying sc_info files!");
    
   // if (![self copySCInfoKeysForApplication:application])
    
    NSString *scinfo_prefix = [baseDirectory stringByAppendingFormat:@"SC_Info/%@", baseName];
    sinfPath = [NSString stringWithFormat:@"%@_%@.sinf", scinfo_prefix, suffix];
    suppPath = [NSString stringWithFormat:@"%@_%@.supp", scinfo_prefix, suffix];
    supfPath = [NSString stringWithFormat:@"%@_%@.supf", scinfo_prefix, suffix];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:[scinfo_prefix stringByAppendingString:@".supf"]])
    {
        [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".supf"] toPath:supfPath error:NULL];
    }
    
    NSLog(@"sinf file yo %@", sinfPath);
    
    [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".sinf"] toPath:sinfPath error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".supp"] toPath:suppPath error:NULL];
    
    return lipoPath;
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

- (NSString *)swapArch:(cpu_subtype_t) swaparch
{
    NSString *workingPath = oldBinaryPath;
    
    NSString *baseName = [workingPath lastPathComponent];
    
    NSString *baseDirectory = [NSString stringWithFormat:@"%@/", [workingPath stringByDeletingLastPathComponent]];
    
    char swapBuffer[4096];
    NSLog(@"##### SWAPPING ARCH #####");
    NSLog(@"local arch %@", [self getPrettyArchName:local_cpusubtype]);
    
    if (local_cpusubtype == swaparch) {
        NSLog(@"UH HELLRO PLIS");
        return NULL;
    }
    
    NSString* suffix = [NSString stringWithFormat:@"%@_lwork", [self getPrettyArchName:OSSwapInt32(swaparch)]];
    workingPath = [NSString stringWithFormat:@"%@_%@", workingPath, suffix]; // assign new path
    
    [[NSFileManager defaultManager] copyItemAtPath:oldBinaryPath toPath:workingPath error: NULL];
    
    FILE* swapbinary = fopen([workingPath UTF8String], "r+");
    
    fseek(swapbinary, 0, SEEK_SET);
    fread(&swapBuffer, sizeof(swapBuffer), 1, swapbinary);
    struct fat_header* swapfh = (struct fat_header*) (swapBuffer);
    
    int i;
    
    struct fat_arch *arch = (struct fat_arch *) &swapfh[1];
    cpu_type_t swap_cputype;
    cpu_subtype_t largest_cpusubtype = 0;
    NSLog(@"arch arch arch ok ok");
    
    for (i = CFSwapInt32(swapfh->nfat_arch); i--;) {
        if (arch->cpusubtype == swaparch) {
            NSLog(@"found arch to swap! %u", OSSwapInt32(swaparch));
            swap_cputype = arch->cputype;
        }
        if (arch->cpusubtype > largest_cpusubtype) {
            largest_cpusubtype = arch->cpusubtype;
        }
        arch++;
    }
    NSLog(@"largest_cpusubtype: %u", CFSwapInt32(largest_cpusubtype));
    
    arch = (struct fat_arch *) &swapfh[1];
    
    for (i = CFSwapInt32(swapfh->nfat_arch); i--;) {
        if (arch->cpusubtype == largest_cpusubtype) {
            if (swap_cputype != arch->cputype) {
                NSLog(@"ERROR: cputypes to swap are incompatible!");
                return false;
            }
            arch->cpusubtype = swaparch;
            NSLog(@"swapp swapp: replaced %u's cpusubtype to %u", CFSwapInt32(arch->cpusubtype), CFSwapInt32(swaparch));
        }
        else if (arch->cpusubtype == swaparch) {
            arch->cpusubtype = largest_cpusubtype;
            NSLog(@"swap swap: replaced %u's cpusubtype to %u", CFSwapInt32(arch->cpusubtype), CFSwapInt32(largest_cpusubtype));
        }
        arch++;
    }
    
    //move the SC_Info keys
    
    NSString *scinfo_prefix = [baseDirectory stringByAppendingFormat:@"SC_Info/%@", baseName];
    
    sinfPath = [NSString stringWithFormat:@"%@_%@.sinf", scinfo_prefix, suffix];
    suppPath = [NSString stringWithFormat:@"%@_%@.supp", scinfo_prefix, suffix];
    supfPath = [NSString stringWithFormat:@"%@_%@.supf", scinfo_prefix, suffix];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:[scinfo_prefix stringByAppendingString:@".supf"]]) {
        [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".supf"] toPath:supfPath error:NULL];
    }
    [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".sinf"] toPath:sinfPath error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".supp"] toPath:suppPath error:NULL];
    
    fseek(swapbinary, 0, SEEK_SET);
    fwrite(swapBuffer, sizeof(swapBuffer), 1, swapbinary);
    
    NSLog(@"swap: Wrote new arch info");
    
    fclose(swapbinary);
    
    return workingPath;
}

- (void)swapBack:(NSString *)path
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:sinfPath error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:suppPath error:NULL];
    if ([[NSFileManager defaultManager] fileExistsAtPath:supfPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:supfPath error:NULL];
    }
}

- (NSString *)swapArchitectureOfApplication:(Application *)application toArchitecture:(uint32_t)swap_arch
{
    char buffer[4096]; // sizeof(fat_header)
    
    if (local_cpusubtype == swap_arch)
    {
        NSLog(@"Dev logic error. No need to swap to the arch the device runs. Hurr.");
        
        return nil;
    }
    
    NSString *tempSwapBinaryPath = [workingDirectory stringByAppendingFormat:@"%@_lwork", [self getPrettyArchName:swap_arch]];
    
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
    
    uint32_t swap_cputype = 0, largest_cpusubtype = 0;
    
    for (int i = 0; i < CFSwapInt32(swap_fat_header->nfat_arch); i++)
    {
        if (arch->cpusubtype == swap_arch)
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
    
    NSLog(@"Largest cpusubtype: %@!", [self getPrettyArchName:largest_cpusubtype]);
    
    arch = (struct fat_arch *)&swap_fat_header[1]; // reset arch increment
    
    for (int i = 0; CFSwapInt32(swap_fat_header->nfat_arch); i++)
    {
        if (arch->cpusubtype == largest_cpusubtype)
        {
            if (swap_cputype != arch->cputype)
            {
                NSLog(@"cputypes to swap are incompatible.");
                
                return nil;
            }
            
            NSLog(@"Replaced %@'s cpusubtype to %@.", [self getPrettyArchName:arch->cpusubtype], [self getPrettyArchName:swap_arch]);
            arch->cpusubtype = swap_arch;
        }
        else if (arch->cpusubtype == swap_arch)
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

- (cpu_type_t)cputype
{
    const struct mach_header *header = _dyld_get_image_header(0);
    return header->cputype;
}

- (cpu_subtype_t)cpusubtype
{
    const struct mach_header *header = _dyld_get_image_header(0);
    return header->cpusubtype;
}

- (ArchCompatibility)compatibleWith:(struct fat_arch *)arch
{
    cpu_type_t cputype = CFSwapInt32(arch->cputype);
    cpu_subtype_t cpusubtype = CFSwapInt32(arch->cpusubtype);
    
    if ((cpusubtype != [self cpusubtype]) || (cputype != [self cputype]))
    {
        if (([self cputype] == CPU_TYPE_ARM) && (cpusubtype > [self cpusubtype]))
        {
            NSLog(@"Can't crack 32-bit arch %@ on %@! Not compatible.", [self getPrettyArchName:cpusubtype], [self getPrettyArchName:[self cpusubtype]]);
            
            return NOT_COMPATIBLE;
        }
        else if (cputype == CPU_TYPE_ARM64)
        {
            if (([self cputype] == CPU_TYPE_ARM64) && (cpusubtype > [self cpusubtype]))
            {
                NSLog(@"Can't crack 64-bit arch %@ on %@! Not compatible", [self getPrettyArchName:cpusubtype], [self getPrettyArchName:[self cpusubtype]]);
                
                return NOT_COMPATIBLE;
            }
            else if ([self cputype] == CPU_TYPE_ARM)
            {
                NSLog(@"Can't crack 64-bit arch on 32-bit device! Not compatible");
                
                return NOT_COMPATIBLE;
            }
        }
        
        return COMPATIBLE_SWAP;
    }
    
    return COMPATIBLE;
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

- (BOOL) removeArchitecture:(struct fat_arch*) removeArch
{
    fpos_t upperArchpos = 0, lowerArchpos = 0;
    char archBuffer[20];
    
    NSString *lipoPath = [NSString stringWithFormat:@"%@_%@_l", newBinaryPath, [self getPrettyArchName:removeArch->cpusubtype]]; // assign a new lipo path
    
    [[NSFileManager defaultManager] copyItemAtPath:newBinaryPath toPath:lipoPath error: NULL];
    
    FILE *lipoOut = fopen([lipoPath UTF8String], "r+"); // prepare the file stream
    char stripBuffer[4096];
    
    fseek(lipoOut, SEEK_SET, 0);
    fread(&stripBuffer, sizeof(buffer), 1, lipoOut);
    
    struct fat_header* fh = (struct fat_header*) (stripBuffer);
    struct fat_arch* arch = (struct fat_arch *) &fh[1];
    
    fseek(lipoOut, 8, SEEK_SET); //skip nfat_arch and bin_magic
    
    BOOL strip_is_last = false;
    
    NSLog(@"searching for copyindex");
    
    for (int i = 0; i < CFSwapInt32(fh->nfat_arch); i++)
    {
        NSLog(@"index %u, nfat_arch %u", i, CFSwapInt32(fh->nfat_arch));
        
        if (CFSwapInt32(arch->cpusubtype) == CFSwapInt32(removeArch->cpusubtype))
        {
            
            NSLog(@"found the upperArch we want to remove!");
            fgetpos(lipoOut, &upperArchpos);
            
            //check the index of the arch to remove
            if ((i+1) == CFSwapInt32(fh->nfat_arch))
            {
                //it's at the bottom
                NSLog(@"at the bottom!! capitalist scums");
                strip_is_last = true;
            }
            else
            {
                NSLog(@"hola");
            }
        }
        
        fseek(lipoOut, sizeof(struct fat_arch), SEEK_CUR);
        arch++;
    }
    
    if (!strip_is_last)
    {
        NSLog(@"strip is not last!")
        
        fseek(lipoOut, 8, SEEK_SET); //skip nfat_arch and bin_magic! reset yo
        arch = (struct fat_arch *) &fh[1];
        
        for (int i = 0; i < CFSwapInt32(fh->nfat_arch); i++)
        {
            //swap the one we want to strip with the next one below it
            NSLog(@"## iterating archs %u removearch:%u", CFSwapInt32(arch->cpusubtype), CFSwapInt32(removeArch->cpusubtype));
            
            if (i == (CFSwapInt32(fh->nfat_arch)) - 1)
            {
                NSLog(@"found the lowerArch we want to copy!");
                
                fgetpos(lipoOut, &lowerArchpos);
            }
            
            fseek(lipoOut, sizeof(struct fat_arch), SEEK_CUR);
            arch++;
        }
        
        if ((upperArchpos == 0) || (lowerArchpos == 0))
        {
            ERROR(@"could not find swap swap swap!");
         
            return false;
        }
        
        //go to the lower arch location
        fseek(lipoOut, (long)lowerArchpos, SEEK_SET);
        fread(&archBuffer, sizeof(archBuffer), 1, lipoOut);
        
        NSLog(@"upperArchpos %lld, lowerArchpos %lld", upperArchpos, lowerArchpos);
        
#warning these all lose integer precision VVV
        
        //write the lower arch data to the upper arch poistion
        fseek(lipoOut, (long)upperArchpos, SEEK_SET);
        fwrite(&archBuffer, sizeof(archBuffer), 1, lipoOut);

        //blank the lower arch position
        fseek(lipoOut, (long)lowerArchpos, SEEK_SET);
    }
    else
    {
        fseek(lipoOut, (long)upperArchpos, SEEK_SET);
    }
    
    memset(archBuffer,'\0',sizeof(archBuffer));
    fwrite(&archBuffer, sizeof(archBuffer), 1, lipoOut);
    
    //change nfat_arch
    
    uint32_t bin_nfat_arch;
    
    fseek(lipoOut, 4, SEEK_SET); //bin_magic
    fread(&bin_nfat_arch, 4, 1, lipoOut); // get the number of fat architectures in the file
    
    NSLog(@"number of architectures %u", CFSwapInt32(bin_nfat_arch));
    
    bin_nfat_arch = bin_nfat_arch - 0x1000000;
    
    NSLog(@"number of architectures %u", CFSwapInt32(bin_nfat_arch));
    
    fseek(lipoOut, 4, SEEK_SET); //bin_magic
    fwrite(&bin_nfat_arch, 4, 1, lipoOut);
    
    NSLog(@"Written new header to binary!");
    
    fclose(lipoOut);
    
    [[NSFileManager defaultManager] removeItemAtPath:newBinaryPath error:NULL];
    [[NSFileManager defaultManager] moveItemAtPath:lipoPath toPath:newBinaryPath error:NULL];
    
    return true;
}


@end