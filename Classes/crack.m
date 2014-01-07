#import "crack.h"
#import "out.h"
#import <Foundation/Foundation.h>
#import "Device.h"
#import "ZipArchive.h"
#include <sys/stat.h>


#define local_arch [Device cpu_subtype]

#define local_cputype [Device cpu_type]


int overdrive_enabled = 0;
BOOL ios6 = FALSE;
BOOL* sixtyfour = FALSE;




NSString* readable_cputype(cpu_type_t type)
{
    NSString *_cputype = @"unknown";
    
    if (type == CPU_TYPE_ARM) {
        _cputype = @"arm";
    }
    else if (type == CPU_TYPE_ARM_64)
    {
        _cputype = @"arm64";
        
    }
    return _cputype;
}

NSString* readable_cpusubtype(cpu_subtype_t subtype)
{
    
    NSString *_cpusubtype = @"unknown";
    
    switch (subtype) {
        case CPU_SUBTYPE_ARM_V7S:
            _cpusubtype = @"armv7s";
            break;
            
        case CPU_SUBTYPE_ARM_V7:
            _cpusubtype = @"armv7";
            break;
        case CPU_SUBTYPE_ARM_V6:
            _cpusubtype = @"armv6";
            break;
        case CPU_SUBTYPE_ARM64_V8:
            _cpusubtype = @"armv8";
            break;
        case CPU_SUBTYPE_ARM64_ALL:
            _cpusubtype = @"arm64";
            break;
            
    }
    
    return _cpusubtype;
}

BOOL dump_binary(FILE *origin, FILE *target, uint32_t top, NSString *originPath, NSString* finalPath) {
    if (sixtyfour) {
        return dump_binary_64(origin, target, top, originPath, finalPath);
    }
    else {
        return dump_binary_32(origin, target, top, originPath, finalPath);
    }
}

BOOL dump_binary_arch(FILE *origin, FILE *target, struct fat_arch* arch, NSString *originPath, NSString* finalPath) {
    if (CFSwapInt32(arch->cputype) == CPU_TYPE_ARM) {
        DEBUG("dumping 32bit offset %u", CFSwapInt32(arch->offset));
        return dump_binary_32(origin, target, CFSwapInt32(arch->offset), originPath, finalPath);
    }
    else {
        DEBUG("dumping 64bit offset %u", CFSwapInt32(arch->offset));
        return dump_binary_64(origin, target, CFSwapInt32(arch->offset), originPath, finalPath);
    }
}

long fsize(const char *file) {
    struct stat st;
    if (stat(file, &st) == 0)
        return st.st_size;
    
    return -1;
}
ZipArchive * createZip(NSString *file) {
    ZipArchive *archiver = [[ZipArchive alloc] init];
    
    if (!file) {
        DEBUG("File string is nil");
        
        return nil;
    }
    
    [archiver CreateZipFile2:file];
    
    return archiver;
}

void zip(ZipArchive *archiver, NSString *folder) {
    BOOL isDir = NO;
    
    NSArray *subpaths;
    NSUInteger total = 0;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if ([fileManager fileExistsAtPath:folder isDirectory:&isDir] && isDir){
        subpaths = [fileManager subpathsAtPath:folder];
        total = [subpaths count];
    }
    
    // I vaguely remember that this is a bad idea on 64-bit but I'm not 100% on that
    int togo = (int)total;
    
    
    for(NSString *path in subpaths){
		togo--;
        
        PERCENT((int)ceil((((double)total - togo) / (double)total) * 100));
        
        // Only add it if it's not a directory. ZipArchive will take care of those.
        NSString *longPath = [folder stringByAppendingPathComponent:path];
        
        if([fileManager fileExistsAtPath:longPath isDirectory:&isDir] && !isDir){
            [archiver addFileToZip:longPath newname:path compressionLevel:compression_level];
        }
    }
    return;
}

void zip_original(ZipArchive *archiver, NSString *folder, NSString *binary, NSString* zip) {
    long size;
    BOOL isDir=NO;
    
    NSArray *subpaths;
    NSUInteger total = 0;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if ([fileManager fileExistsAtPath:folder isDirectory:&isDir] && isDir){
        subpaths = [fileManager subpathsAtPath:folder];
        total = [subpaths count];
    }
    
    int togo = (int)total;
    
    
    for(NSString *path in subpaths) {
		togo--;
        
        if (([path rangeOfString:@".app"].location != NSNotFound) && ([path rangeOfString:@"SC_Info"].location == NSNotFound) && ([path rangeOfString:@"Library"].location == NSNotFound) && ([path rangeOfString:@"tmp"].location == NSNotFound) && ([path rangeOfString:[NSString stringWithFormat:@".app/%@", binary]].location == NSNotFound)) {
            PERCENT((int)ceil((((double)total - togo) / (double)total) * 100));
            
            // Only add it if it's not a directory. ZipArchive will take care of those.
            NSString *longPath = [folder stringByAppendingPathComponent:path];
            
            if([fileManager fileExistsAtPath:longPath isDirectory:&isDir] && !isDir){
                size += fsize([longPath UTF8String]);
                [archiver addFileToZip:longPath newname:[NSString stringWithFormat:@"Payload/%@", path] compressionLevel:compression_level];
            }
        }
    }
    
    return;
}


NSString * crack_application(NSString *application_basedir, NSString *basename, NSString* version) {
    VERBOSE("Creating working directory...");
    
    stripHeaders = [[NSMutableArray alloc] init];
    
	NSString *workingDir = [NSString stringWithFormat:@"%@%@/", @"/tmp/clutch_", genRandStringLength(8)];
	if (![[NSFileManager defaultManager] createDirectoryAtPath:[workingDir stringByAppendingFormat:@"Payload/%@", basename] withIntermediateDirectories:YES attributes:[NSDictionary
                                                                                                                                                                        dictionaryWithObjects:[NSArray arrayWithObjects:@"mobile", @"mobile", nil]
                                                                                                                                                                        forKeys:[NSArray arrayWithObjects:@"NSFileOwnerAccountName", @"NSFileGroupOwnerAccountName", nil]
                                                                                                                                                                        ] error:NULL]) {
		printf("error: Could not create working directory\n");
		return nil;
	}
	
    VERBOSE("Performing initial analysis...");
	struct stat statbuf_info;
	stat([[application_basedir stringByAppendingString:@"Info.plist"] UTF8String], &statbuf_info);
	time_t ist_atime = statbuf_info.st_atime;
	time_t ist_mtime = statbuf_info.st_mtime;
	struct utimbuf oldtimes_info;
	oldtimes_info.actime = ist_atime;
	oldtimes_info.modtime = ist_mtime;
	
	NSMutableDictionary *infoplist = [NSMutableDictionary dictionaryWithContentsOfFile:[application_basedir stringByAppendingString:@"Info.plist"]];
	if (infoplist == nil) {
		printf("error: Could not open Info.plist\n");
		goto fatalc;
	}
	
	if ([(NSString *)[ClutchConfiguration getValue:@"CheckMinOS"] isEqualToString:@"YES"]) {
		NSString *MinOS;
		if (nil != (MinOS = [infoplist objectForKey:@"MinimumOSVersion"])) {
			if (strncmp([MinOS UTF8String], "2", 1) == 0) {
				printf("notice: added SignerIdentity field (MinOS 2.X)\n");
				[infoplist setObject:@"Apple iPhone OS Application Signing" forKey:@"SignerIdentity"];
				[infoplist writeToFile:[application_basedir stringByAppendingString:@"Info.plist"] atomically:NO];
			}
		}
	}
	
	utime([[application_basedir stringByAppendingString:@"Info.plist"] UTF8String], &oldtimes_info);
	
	NSString *binary_name = [infoplist objectForKey:@"CFBundleExecutable"];
	
	NSString *fbinary_path = init_crack_binary(application_basedir, basename, workingDir, infoplist);
	if (fbinary_path == nil) {
		printf("error: Could not crack binary\n");
		goto fatalc;
	}
	
	NSMutableDictionary *metadataPlist = [NSMutableDictionary dictionaryWithContentsOfFile:[application_basedir stringByAppendingString:@"/../iTunesMetadata.plist"]];
	
	[[NSFileManager defaultManager] copyItemAtPath:[application_basedir stringByAppendingString:@"/../iTunesArtwork"] toPath:[workingDir stringByAppendingString:@"iTunesArtwork"] error:NULL];
    
	if (![[ClutchConfiguration getValue:@"RemoveMetadata"] isEqualToString:@"YES"]) {
        VERBOSE("Censoring iTunesMetadata.plist...");
		struct stat statbuf_metadata;
		stat([[application_basedir stringByAppendingString:@"/../iTunesMetadata.plist"] UTF8String], &statbuf_metadata);
		time_t mst_atime = statbuf_metadata.st_atime;
		time_t mst_mtime = statbuf_metadata.st_mtime;
		struct utimbuf oldtimes_metadata;
		oldtimes_metadata.actime = mst_atime;
		oldtimes_metadata.modtime = mst_mtime;
		
        NSString *fake_email;
        NSDate *fake_purchase_date = [NSDate dateWithTimeIntervalSince1970:1251313938];
        
        if (nil == (fake_email = [ClutchConfiguration getValue:@"MetadataEmail"])) {
            fake_email = @"steve@rim.jobs";
        }
        
        if (nil == (fake_purchase_date = [ClutchConfiguration getValue:@"MetadataPurchaseDate"])) {
            fake_purchase_date = [NSDate dateWithTimeIntervalSince1970:1251313938];
        }
        
		NSDictionary *censorList = [NSDictionary dictionaryWithObjectsAndKeys:fake_email, @"appleId", fake_purchase_date, @"purchaseDate", nil];
		if ([[ClutchConfiguration getValue:@"CheckMetadata"] isEqualToString:@"YES"]) {
			NSDictionary *noCensorList = [NSDictionary dictionaryWithObjectsAndKeys:
										  @"", @"artistId",
										  @"", @"artistName",
										  @"", @"buy-only",
										  @"", @"buyParams",
										  @"", @"copyright",
										  @"", @"drmVersionNumber",
										  @"", @"fileExtension",
										  @"", @"genre",
										  @"", @"genreId",
										  @"", @"itemId",
										  @"", @"itemName",
										  @"", @"gameCenterEnabled",
										  @"", @"gameCenterEverEnabled",
										  @"", @"kind",
										  @"", @"playlistArtistName",
										  @"", @"playlistName",
										  @"", @"price",
										  @"", @"priceDisplay",
										  @"", @"rating",
										  @"", @"releaseDate",
										  @"", @"s",
										  @"", @"softwareIcon57x57URL",
										  @"", @"softwareIconNeedsShine",
										  @"", @"softwareSupportedDeviceIds",
										  @"", @"softwareVersionBundleId",
										  @"", @"softwareVersionExternalIdentifier",
                                          @"", @"UIRequiredDeviceCapabilities",
										  @"", @"softwareVersionExternalIdentifiers",
										  @"", @"subgenres",
										  @"", @"vendorId",
										  @"", @"versionRestrictions",
										  @"", @"com.apple.iTunesStore.downloadInfo",
										  @"", @"bundleVersion",
										  @"", @"bundleShortVersionString",
                                          @"", @"product-type",
                                          @"", @"is-purchased-redownload",
                                          @"", @"asset-info", nil];
			for (id plistItem in metadataPlist) {
				if (([noCensorList objectForKey:plistItem] == nil) && ([censorList objectForKey:plistItem] == nil)) {
					printf("\033[0;37;41mwarning: iTunesMetadata.plist item named '\033[1;37;41m%s\033[0;37;41m' is unrecognized\033[0m\n", [plistItem UTF8String]);
				}
			}
		}
		
		for (id censorItem in censorList) {
            if (censorItem == nil) {
                DEBUG("nil key");
            } else {
                [metadataPlist setObject:[censorList objectForKey:censorItem] forKey:censorItem];
            }
		}
		[metadataPlist removeObjectForKey:@"com.apple.iTunesStore.downloadInfo"];
		[metadataPlist writeToFile:[workingDir stringByAppendingString:@"iTunesMetadata.plist"] atomically:NO];
		utime([[workingDir stringByAppendingString:@"iTunesMetadata.plist"] UTF8String], &oldtimes_metadata);
		utime([[application_basedir stringByAppendingString:@"/../iTunesMetadata.plist"] UTF8String], &oldtimes_metadata);
	}
	
	NSString *crackerName = [ClutchConfiguration getValue:@"CrackerName"];
    if (crackerName == nil) {
        crackerName = @"no-name-cracker";
    }
	if ([[ClutchConfiguration getValue:@"CreditFile"] isEqualToString:@"YES"]) {
        VERBOSE("Creating credit file...");
		FILE *fh = fopen([[workingDir stringByAppendingFormat:@"_%@", crackerName] UTF8String], "w");
		NSString *creditFileData = [NSString stringWithFormat:@"%@ (%@) Cracked by %@ using %s.", [infoplist objectForKey:@"CFBundleDisplayName"], [infoplist objectForKey:@"CFBundleVersion"], crackerName, CLUTCH_VERSION];
		fwrite([creditFileData UTF8String], [creditFileData lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 1, fh);
		fclose(fh);
	}
    
    if (overdrive_enabled) {
        VERBOSE("Including overdrive dylib...");
        [[NSFileManager defaultManager] copyItemAtPath:@"/var/lib/clutch/overdrive.dylib" toPath:[workingDir stringByAppendingFormat:@"Payload/%@/overdrive.dylib", basename] error:NULL];
        
        VERBOSE("Creating fake SC_Info data...");
        // create fake SC_Info directory
        [[NSFileManager defaultManager] createDirectoryAtPath:[workingDir stringByAppendingFormat:@"Payload/%@/SF_Info/", basename] withIntermediateDirectories:YES attributes:nil error:NULL];
        VERBOSE("DEBUG: made fake directory");
        // create fake SC_Info SINF file
        FILE *sinfh = fopen([[workingDir stringByAppendingFormat:@"Payload/%@/SF_Info/%@.sinf", basename, binary_name] UTF8String], "w");
        void *sinf = generate_sinf([[metadataPlist objectForKey:@"itemId"] intValue], (char *)[crackerName UTF8String], [[metadataPlist objectForKey:@"vendorId"] intValue]);
        fwrite(sinf, CFSwapInt32(*(uint32_t *)sinf), 1, sinfh);
        fclose(sinfh);
        free(sinf);
        
        // create fake SC_Info SUPP file
        FILE *supph = fopen([[workingDir stringByAppendingFormat:@"Payload/%@/SF_Info/%@.supp", basename, binary_name] UTF8String], "w");
        uint32_t suppsize;
        void *supp = generate_supp(&suppsize);
        fwrite(supp, suppsize, 1, supph);
        fclose(supph);
        free(supp);
    }
    
    VERBOSE("Packaging IPA file...");
    
    // filename addendum
    NSMutableString *addendum = [[NSMutableString alloc]init];
    
    if (overdrive_enabled) {
        [addendum appendString:@"-OD"];
    }
    if ([(NSString *)[ClutchConfiguration getValue:@"CheckMinOS"] isEqualToString:@"YES"]) {
        [addendum appendString: [NSString stringWithFormat:@"-iOS-%@", [infoplist objectForKey:@"MinimumOSVersion"]]];
    }
    
	NSString *ipapath;
    NSString *bundleName;
    
    if (infoplist[@"CFBundleDisplayName"] == nil || infoplist[@"CFBundleDisplayName"] == NULL) {
        DEBUG("using CFBundleName");
        bundleName = infoplist[@"CFBundleName"];
    } else {
        bundleName = infoplist[@"CFBundleDisplayName"];
    }
    
	if ([[ClutchConfiguration getValue:@"FilenameCredit"] isEqualToString:@"YES"]) {
		ipapath = [NSString stringWithFormat:@"/var/root/Documents/Cracked/%@-v%@-%@%@-(%@).ipa", [bundleName stringByReplacingOccurrencesOfString:@"/" withString:@"_"], [infoplist objectForKey:@"CFBundleVersion"], crackerName, addendum, [NSString stringWithUTF8String:CLUTCH_VERSION]];
	} else {
		ipapath = [NSString stringWithFormat:@"/var/root/Documents/Cracked/%@-v%@%@-(%@).ipa", [bundleName stringByReplacingOccurrencesOfString:@"/" withString:@"_"], [infoplist objectForKey:@"CFBundleVersion"], addendum, [NSString stringWithUTF8String:CLUTCH_VERSION]];
	}
	[[NSFileManager defaultManager] createDirectoryAtPath:@"/var/root/Documents/Cracked/" withIntermediateDirectories:TRUE attributes:nil error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:ipapath error:NULL];
    
	int config_compression = [[ClutchConfiguration getValue:@"CompressionLevel"] intValue];
	if (!((config_compression < 10) && (config_compression > -2))) {
        printf("error: unknown compression level");
        goto fatalc;
    }
    else {
        compression_level = config_compression;
    }
    printf("\ncompression level: %d\n", compression_level);
    
    
    if (new_zip == 1) {
        NOTIFY("Compressing original application (native zip) (1/2)...");
        ZipArchive *archiver = createZip(ipapath);
        zip_original(archiver, [application_basedir stringByAppendingString:@"../"], binary_name, ipapath);
        stop_bar();
        NOTIFY("Compressing second cracked application (native zip) (2/2)...");
        zip(archiver, workingDir);
        stop_bar();
        [archiver CloseZipFile2];
    }
    else {
        
        NSString *compressionArguments = @"";
        if (compression_level != -1) {
            compressionArguments = [NSString stringWithFormat:@"-%d", compression_level];
        }
        NOTIFY("Compressing cracked application (1/2)...");
        system([[NSString stringWithFormat:@"cd %@; zip %@ -m -r \"%@\" * 2>&1> /dev/null", workingDir, compressionArguments, ipapath] UTF8String]);
        [[NSFileManager defaultManager] moveItemAtPath:[workingDir stringByAppendingString:@"Payload"] toPath:[workingDir stringByAppendingString:@"Payload_1"] error:NULL];
        
        
        [[NSFileManager defaultManager] createSymbolicLinkAtPath:[workingDir stringByAppendingString:@"Payload"] withDestinationPath:[application_basedir stringByAppendingString:@"/../"] error:NULL];
        NOTIFY("Compressing original application (2/2)...");
        system([[NSString stringWithFormat:@"cd %@; zip %@ -u -y -r -n .jpg:.JPG:.jpeg:.png:.PNG:.gif:.GIF:.Z:.gz:.zip:.zoo:.arc:.lzh:.rar:.arj:.mp3:.mp4:.m4a:.m4v:.ogg:.ogv:.avi:.flac:.aac \"%@\" Payload/* -x Payload/iTunesArtwork Payload/iTunesMetadata.plist \"Payload/Documents/*\" \"Payload/Library/*\" \"Payload/tmp/*\" \"Payload/*/%@\" \"Payload/*/SC_Info/*\" 2>&1> /dev/null", workingDir, compressionArguments, ipapath, binary_name] UTF8String]);
        
        stop_bar();
        
    }
    
	[[NSFileManager defaultManager] removeItemAtPath:workingDir error:NULL];
    
 
    NSMutableDictionary *dict;
        
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/etc/clutch_cracked.plist"]) {
        dict = [[NSMutableDictionary alloc] initWithContentsOfFile:@"/etc/clutch_cracked.plist"];
    } else {
        [[NSFileManager defaultManager] createFileAtPath:@"/etc/clutch_cracked.plist" contents:nil attributes:nil];
        dict = [[NSMutableDictionary alloc] init];
    }
        
    [dict setObject:version forKey:bundleName];
    [dict writeToFile:@"/etc/clutch_cracked.plist" atomically:YES];
        
    [dict release];
    
	return ipapath;
	
fatalc:
	[[NSFileManager defaultManager] removeItemAtPath:workingDir error:NULL];
	return nil;
}
NSString * init_crack_binary(NSString *application_basedir, NSString *bdir, NSString *workingDir, NSDictionary *infoplist) {
    VERBOSE("Performing cracking preflight...");
	NSString *binary_name = [infoplist objectForKey:@"CFBundleExecutable"];
	NSString *binary_path = [application_basedir stringByAppendingString:binary_name];
	NSString *fbinary_path = [workingDir stringByAppendingFormat:@"Payload/%@/%@", bdir, binary_name];
	
	NSString *err = nil;
	
	struct stat statbuf;
	stat([binary_path UTF8String], &statbuf);
	time_t bst_atime = statbuf.st_atime;
	time_t bst_mtime = statbuf.st_mtime;
	
	NSString *ret = crack_binary(binary_path, fbinary_path, &err);
	
	struct utimbuf oldtimes;
	oldtimes.actime = bst_atime;
	oldtimes.modtime = bst_mtime;
	
	utime([binary_path UTF8String], &oldtimes);
	utime([fbinary_path UTF8String], &oldtimes);
	
	if (ret == nil)
		printf("error: %s\n", [err UTF8String]);
	
	return ret;
}

int get_arch(struct fat_arch* arch) {
    int i;
    if (arch->cputype == CPUTYPE_32) {
        DEBUG("32bit portion detected %u", arch->cpusubtype);
        switch (arch->cpusubtype) {
            case ARMV7S_SUBTYPE:
                DEBUG("armv7s portion detected");
                i = 11;
                break;
            case ARMV7_SUBTYPE:
                DEBUG("armv7 portion detected");
                i = 9;
                break;
            case ARMV6_SUBTYPE:
                DEBUG("armv6 portion detected");
                i = 6;
                break;
            default:
                DEBUG("ERROR: unknown 32bit portion detected %u", arch->cpusubtype);
                i = -1;
                break;
        }
    }
    else if (arch->cputype == CPUTYPE_64) {
        switch (arch->cpusubtype) {
            case ARM64_SUBTYPE:
                DEBUG("arm64 portion detected! 64bit!!");
                i = 64;
                break;
            default:
                DEBUG("ERROR: unknown 64bit portion detected");
                i = -1;
                break;
        }
    }
    return i;
}

NSString* strip_arch(NSString* oldbinaryPath, cpu_subtype_t keep_arch)
{
    NSString *baseName = [oldbinaryPath lastPathComponent]; // get the basename (name of the binary)
	NSString *baseDirectory = [NSString stringWithFormat:@"%@/", [oldbinaryPath stringByDeletingLastPathComponent]];
    
    DebugLog(@"##### STRIPPING ARCH #####");
    NSString* suffix = [NSString stringWithFormat:@"arm%u_lwork", CFSwapInt32(keep_arch)];
    NSString *lipoPath = [NSString stringWithFormat:@"%@_%@", oldbinaryPath, suffix]; // assign a new lipo path
    DebugLog(@"lipo path %s", [lipoPath UTF8String]);
    [[NSFileManager defaultManager] copyItemAtPath:oldbinaryPath toPath:lipoPath error: NULL];
    FILE *lipoOut = fopen([lipoPath UTF8String], "r+"); // prepare the file stream
    char stripBuffer[4096];
    fseek(lipoOut, SEEK_SET, 0);
    fread(&stripBuffer, sizeof(buffer), 1, lipoOut);
    struct fat_header* fh = (struct fat_header*) (stripBuffer);
    struct fat_arch* arch = (struct fat_arch *) &fh[1];
    struct fat_arch copy;
    BOOL foundarch = FALSE;
    
    fseek(lipoOut, 8, SEEK_SET); //skip nfat_arch and bin_magic
    
    for (int i = 0; i < CFSwapInt32(fh->nfat_arch); i++) {
        if (arch->cpusubtype == keep_arch) {
            DebugLog(@"found arch to keep %u! Storing it", CFSwapInt32(keep_arch));
            foundarch = TRUE;
            fread(&copy, sizeof(struct fat_arch), 1, lipoOut);
        }
        else {
            fseek(lipoOut, sizeof(struct fat_arch), SEEK_CUR);
        }
        arch++;
    }
    if (!foundarch) {
        DebugLog(@"error: could not find arch to keep!");
        int *p = NULL;
        *p = 1;
        return false;
    }
    fseek(lipoOut, 8, SEEK_SET);
    fwrite(&copy, sizeof(struct fat_arch), 1, lipoOut);
    char data[20];
    memset(data,'\0',sizeof(data));
    for (int i = 0; i < (CFSwapInt32(fh->nfat_arch) - 1); i++) {
        DebugLog(@"blanking arch! %u", i);
        fwrite(data, sizeof(data), 1, lipoOut);
    }
    
    //change nfat_arch
    DebugLog(@"changing nfat_arch");
    
    //fseek(lipoOut, 4, SEEK_SET); //bin_magic
    //fread(&bin_nfat_arch, 4, 1, lipoOut); // get the number of fat architectures in the file
    //VERBOSE("DEBUG: number of architectures %u", CFSwapInt32(bin_nfat_arch));
    uint32_t bin_nfat_arch = 0x1000000;
    
    DebugLog(@"number of architectures %u", CFSwapInt32(bin_nfat_arch));
    fseek(lipoOut, 4, SEEK_SET); //bin_magic
    fwrite(&bin_nfat_arch, 4, 1, lipoOut);
    
    DebugLog(@"Written new header to binary!");
    fclose(lipoOut);
    DebugLog(@"copying sc_info files!");
    NSString *scinfo_prefix = [baseDirectory stringByAppendingFormat:@"SC_Info/%@", baseName];
    sinf_file = [NSString stringWithFormat:@"%@_%@.sinf", scinfo_prefix, suffix];
    supp_file = [NSString stringWithFormat:@"%@_%@.supp", scinfo_prefix, suffix];
    supf_file = [NSString stringWithFormat:@"%@_%@.supf", scinfo_prefix, suffix];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:[scinfo_prefix stringByAppendingString:@".supf"]]) {
        [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".supf"] toPath:supf_file error:NULL];
    }
    NSLog(@"sinf file yo %@", sinf_file);
    [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".sinf"] toPath:sinf_file error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".supp"] toPath:supp_file error:NULL];
    
    return lipoPath;
}



NSString* swap_arch(NSString *binaryPath, NSString* baseDirectory, NSString* baseName, cpu_subtype_t swaparch) {
    
    char swapBuffer[4096];
    DebugLog(@"##### SWAPPING ARCH #####");
    DebugLog(@"local arch %@", readable_cpusubtype(local_arch));
    
    if (local_arch == swaparch) {
        NSLog(@"UH HELLRO PLIS");
        return NULL;
    }
    
    NSString* suffix = [NSString stringWithFormat:@"%d_lwork", CFSwapInt32(swaparch)];
    NSString* workingPath = [NSString stringWithFormat:@"%@_%@", binaryPath, suffix]; // assign new path
    
    [[NSFileManager defaultManager] copyItemAtPath:binaryPath toPath:workingPath error: NULL];
    
    FILE* swapbinary = fopen([workingPath UTF8String], "r+");
    
    fseek(swapbinary, 0, SEEK_SET);
    fread(&swapBuffer, sizeof(swapBuffer), 1, swapbinary);
    struct fat_header* swapfh = (struct fat_header*) (swapBuffer);
    
    int i;
    
    struct fat_arch *arch = (struct fat_arch *) &swapfh[1];
    cpu_type_t swap_cputype;
    cpu_subtype_t largest_cpusubtype = 0;
    NSLog(@"arch arch arch ok ok");

   for (int i = 0; i < CFSwapInt32(swapfh->nfat_arch); i++) {
        if (arch->cpusubtype == swaparch) {
            DebugLog(@"swap_cputype: %u", swaparch);
            swap_cputype = arch->cputype;
        }
        if (CFSwapInt32(arch->cpusubtype) > largest_cpusubtype) {
            largest_cpusubtype = arch->cpusubtype;
             DebugLog(@"largest_cputype: %u", arch->cpusubtype);
        }
        arch++;
    }
    DebugLog(@"##### largest_cpusubtype: %u ####", largest_cpusubtype);
    
    arch = (struct fat_arch *) &swapfh[1];
    
    for (int i = 0; i < CFSwapInt32(swapfh->nfat_arch); i++) {
       
        if (arch->cpusubtype == largest_cpusubtype) {
            if (swap_cputype != arch->cputype) {
                DebugLog(@"ERROR: cputypes to swap are incompatible!");
                return false;
            }
            arch->cpusubtype = swaparch;
            DebugLog(@"swapp swapp: replaced %u's cpusubtype to %u", CFSwapInt32(arch->cpusubtype), CFSwapInt32(swaparch));
        }
        else if (arch->cpusubtype == swaparch) {
            arch->cpusubtype = largest_cpusubtype;
            DebugLog(@"swap swap: replaced %u's cpusubtype to %u", CFSwapInt32(arch->cpusubtype), CFSwapInt32(largest_cpusubtype));
        }
        arch++;
    }
    
    //move the SC_Info keys
    
    NSString *scinfo_prefix = [baseDirectory stringByAppendingFormat:@"SC_Info/%@", baseName];
    
    sinf_file = [NSString stringWithFormat:@"%@_%@.sinf", scinfo_prefix, suffix];
    supp_file = [NSString stringWithFormat:@"%@_%@.supp", scinfo_prefix, suffix];
    supf_file = [NSString stringWithFormat:@"%@_%@.supf", scinfo_prefix, suffix];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:[scinfo_prefix stringByAppendingString:@".supf"]]) {
        [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".supf"] toPath:supf_file error:NULL];
    }
    [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".sinf"] toPath:sinf_file error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:[scinfo_prefix stringByAppendingString:@".supp"] toPath:supp_file error:NULL];
    
    fseek(swapbinary, 0, SEEK_SET);
    fwrite(swapBuffer, sizeof(swapBuffer), 1, swapbinary);
    
    DebugLog(@"swap: Wrote new arch info");
    
    fclose(swapbinary);
    
    return workingPath;
    
}

/*
void swap_back(NSString *binaryPath, NSString* baseDirectory, NSString* baseName) {
    // remove swapped binary
    NSString *scinfo_prefix = [baseDirectory stringByAppendingFormat:@"SC_Info/%@", baseName];
    [[NSFileManager defaultManager] removeItemAtPath:binaryPath error:NULL];
    [[NSFileManager defaultManager] moveItemAtPath:sinf_file toPath:[scinfo_prefix stringByAppendingString:@".sinf"] error:NULL];
    [[NSFileManager defaultManager] moveItemAtPath:supp_file toPath:[scinfo_prefix stringByAppendingString:@".supp"] error:NULL];
    if ([[NSFileManager defaultManager] fileExistsAtPath:supf_file]) {
        [[NSFileManager defaultManager] moveItemAtPath:supf_file toPath:[scinfo_prefix stringByAppendingString:@".supf"] error:NULL];
    }
    
    VERBOSE("DEBUG: Removed SC_Info files");
}*/
void removeArchitecture(NSString* newbinaryPath, struct fat_arch* removeArch) {
    struct fat_arch *lowerArch;
    fpos_t upperArchpos, lowerArchpos;
    NSString *lipoPath = [NSString stringWithFormat:@"%@_l", newbinaryPath]; // assign a new lipo path
    [[NSFileManager defaultManager] copyItemAtPath:newbinaryPath toPath:lipoPath error: NULL];
    FILE *lipoOut = fopen([lipoPath UTF8String], "r+"); // prepare the file stream
    char stripBuffer[4096];
    fseek(lipoOut, SEEK_SET, 0);
    fread(&stripBuffer, sizeof(buffer), 1, lipoOut);
    struct fat_header* fh = (struct fat_header*) (stripBuffer);
    struct fat_arch* arch = (struct fat_arch *) &fh[1];
    
    fseek(lipoOut, 8, SEEK_SET); //skip nfat_arch and bin_magic
    
    for (int i = 0; i < CFSwapInt32(fh->nfat_arch); i++) {
        //swap the one we want to strip with the next one below it
        if (arch == removeArch) {
            DEBUG("found the upperArch we want to copy!");
            fgetpos(lipoOut, &upperArchpos);
            
        }
        else if (i == (CFSwapInt32(fh->nfat_arch)) - 1) {
            DEBUG("found the lowerArch we want to copy!");
            fgetpos(lipoOut, &lowerArchpos);
            lowerArch = arch;
        }
        fseek(lipoOut, sizeof(struct fat_arch), SEEK_CUR);
        arch++;
    }
    
    //go to the upper arch location
    fseek(lipoOut, upperArchpos, SEEK_SET);
    //write the lower arch data to the upper arch poistion
    fwrite(&lowerArch, sizeof(struct fat_arch), 1, lipoOut);
    //blank the lower arch position
    fseek(lipoOut, lowerArch, SEEK_SET);
    char data[20];
    memset(data,'\0',sizeof(data));
    fwrite(&data, sizeof(data), 1, lipoOut);
    
    //change nfat_arch
    
    uint32_t bin_nfat_arch;
    
    fseek(lipoOut, 4, SEEK_SET); //bin_magic
    fread(&bin_nfat_arch, 4, 1, lipoOut); // get the number of fat architectures in the file
    DEBUG("number of architectures %u", CFSwapInt32(bin_nfat_arch));
    bin_nfat_arch = bin_nfat_arch - 0x1000000;
    
    DEBUG("number of architectures %u", CFSwapInt32(bin_nfat_arch));
    fseek(lipoOut, 4, SEEK_SET); //bin_magic
    fwrite(&bin_nfat_arch, 4, 1, lipoOut);
    
    DEBUG("Written new header to binary!");
    fclose(lipoOut);
    
    [[NSFileManager defaultManager] removeItemAtPath:newbinaryPath error:NULL];
    [[NSFileManager defaultManager] moveItemAtPath:lipoPath toPath:newbinaryPath error:NULL];
}

void swap_back(NSString *binaryPath, NSString* baseDirectory, NSString* baseName) {
    // remove swapped binary
    [[NSFileManager defaultManager] removeItemAtPath:binaryPath error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:sinf_file error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:supp_file error:NULL];
    if ([[NSFileManager defaultManager] fileExistsAtPath:supf_file]) {
        [[NSFileManager defaultManager] removeItemAtPath:supf_file error:NULL];
    }
    DEBUG("Removed SC_Info files");
}




BOOL* lipoBinary(FILE* newbinary, NSString* newbinaryPath, struct fat_arch* arch) {
    
    // Lipo out the data
    NSString *lipoPath = [NSString stringWithFormat:@"%@_l", newbinaryPath]; // assign a new lipo path
    FILE *lipoOut = fopen([lipoPath UTF8String], "w+"); // prepare the file stream
    fseek(newbinary, CFSwapInt32(arch->offset), SEEK_SET); // go to the armv6 offset
    void *tmp_b = malloc(0x1000); // allocate a temporary buffer
    
    NSUInteger remain = CFSwapInt32(arch->size);
    
    while (remain > 0) {
        if (remain > 0x1000) {
            // move over 0x1000
            fread(tmp_b, 0x1000, 1, newbinary);
            fwrite(tmp_b, 0x1000, 1, lipoOut);
            remain -= 0x1000;
        } else {
            // move over remaining and break
            fread(tmp_b, remain, 1, newbinary);
            fwrite(tmp_b, remain, 1, lipoOut);
            break;
        }
    }
    
    free(tmp_b); // free temporary buffer
    fclose(lipoOut); // close lipo output stream
    fclose(newbinary); // close new binary stream
    fclose(oldbinary); // close old binary stream
    
    [[NSFileManager defaultManager] removeItemAtPath:newbinaryPath error:NULL]; // remove old file
    [[NSFileManager defaultManager] moveItemAtPath:lipoPath toPath:newbinaryPath error:NULL]; // move the lipo'd binary to the final path
    chown([newbinaryPath UTF8String], 501, 501); // adjust permissions
    chmod([newbinaryPath UTF8String], 0777); // adjust permissions
    return true;
}



NSString *crack_binary(NSString *binaryPath, NSString *finalPath, NSString **error) {
	[[NSFileManager defaultManager] copyItemAtPath:binaryPath toPath:finalPath error:NULL]; //copy the original binary to that path
    
    
   	NSString *baseName = [binaryPath lastPathComponent]; // get the basename (name of the binary)
	NSString *baseDirectory = [NSString stringWithFormat:@"%@/", [binaryPath stringByDeletingLastPathComponent]]; // get the base directory

    
  
    
    DebugLog(@"attempting to crack binary to file! finalpath %@", finalPath);
    DebugLog(@"DEBUG: binary path %@", binaryPath);
    

    
    DEBUG("basedir ok");
    // open streams from both files
    
    FILE *oldbinary, *newbinary;
    
	oldbinary = fopen([binaryPath UTF8String], "r+");
	newbinary = fopen([finalPath UTF8String], "r+");
    DEBUG("open ok");
	
    if (oldbinary==NULL) {
        
        if (newbinary!=NULL) {
            fclose(newbinary);
        }
        
        //*error = [NSString stringWithFormat:@"[crack_binary] Error opening file: %s.\n", strerror(errno)];
        return NO;
    }
    
    fread(&buffer, sizeof(buffer), 1, oldbinary);
    
    DebugLog(@"local arch - %@", readable_cputype(local_arch));
    
    struct fat_header* fh  = (struct fat_header*) (buffer);
    
    switch (fh->magic) {
            //64-bit thin
        case MH_MAGIC_64: {
            struct mach_header_64 *mh64 = (struct mach_header_64 *)fh;
            
            DebugLog(@"64-bit Thin %@ binary detected",readable_cputype(mh64->cpusubtype));
            
            DebugLog(@"mach_header_64 %x %u %u",mh64->magic,mh64->cputype,mh64->cpusubtype);
            
            if (local_cputype == CPU_TYPE_ARM)
            {
                DebugLog(@"Can't crack 64bit on 32bit device");
                return NO;
            }
            
            if (mh64->cpusubtype != local_arch) {
                DebugLog(@"Can't crack %u on %u device",mh64->cpusubtype,local_arch);
                return NO;
            }
            if (!dump_binary_64(oldbinary, newbinary, 0, binaryPath, finalPath)) {
                // Dumping failed
                DebugLog(@"Failed to dump 64bit arch %@", readable_cpusubtype(mh64->cpusubtype));
                return NO;
            }
            return YES;
            break;
        }
            //32-bit thin
        case MH_MAGIC: {
            struct mach_header *mh32 = (struct mach_header *)fh;
            
            DebugLog(@"32bit Thin %@ binary detected",readable_cpusubtype(mh32->cpusubtype));
            
            DebugLog(@"mach_header %x %u %u",mh32->magic,mh32->cputype,mh32->cpusubtype);
            
            BOOL godMode32 = NO;
            
            BOOL godMode64 = NO;
            
            if (local_cputype == CPU_TYPE_ARM_64) {
                DebugLog(@"local_arch = God64");
                DebugLog(@"[TRU GOD MODE ENABLED]");
                godMode64 = YES;
                godMode32 = YES;
            }
            
            if ((!godMode64)&&(local_arch == CPU_SUBTYPE_ARM_V7S)) {
                DebugLog(@"local_arch = God32");
                DebugLog(@"[32bit GOD MODE ENABLED]");
                godMode32 = YES;
            }
            
            if ((!godMode32)&&(mh32->cpusubtype>local_arch)) {
                DebugLog(@"Can't crack 32bit(%u) on 32bit(%u) device",mh32->cpusubtype,local_arch);
                return NO;
            }
            
            if (!dump_binary_32(oldbinary, newbinary, 0, binaryPath, finalPath)) {
                // Dumping failed
                DebugLog(@"Failed to dump %@", readable_cpusubtype(mh32->cpusubtype));
                return NO;
            }
            
            return YES;
            break;
        }
            //FAT
        case FAT_CIGAM: {
            NSMutableArray *stripHeaders = [NSMutableArray new];
            
            NSUInteger archCount = CFSwapInt32(fh->nfat_arch);
            
            struct fat_arch *arch = (struct fat_arch *) &fh[1]; //(struct fat_arch *) (fh + sizeof(struct fat_header));
            
            DebugLog(@"FAT binary detected");
            
            DebugLog(@"nfat_arch %lu",(unsigned long)archCount);
            
            struct fat_arch* compatibleArch;
            //loop + crack
            for (int i = 0; i < CFSwapInt32(fh->nfat_arch); i++) {
                DEBUG("currently cracking arch %u", CFSwapInt32(arch->cpusubtype));
                switch ([Device compatibleWith:arch]) {
                    case COMPATIBLE: {
                        DEBUG("arch compatible with device!");
                        
                        //go ahead and crack
                        
                        if (!dump_binary_arch(oldbinary, newbinary, arch, binaryPath, finalPath)) {

                            // Dumping failed
                            
                            DebugLog(@"Cannot crack unswapped arm%u portion of binary.", CFSwapInt32(arch->cpusubtype));
                            
                            //*error = @"Cannot crack unswapped portion of binary.";
                            fclose(newbinary); // close the new binary stream
                            fclose(oldbinary); // close the old binary stream
                            [[NSFileManager defaultManager] removeItemAtPath:finalPath error:NULL]; // delete the new binary
                            return NO;
                        }
                        compatibleArch = arch;
                        break;
                        
                    }
                    case NOT_COMPATIBLE: {
                        DEBUG("arch not compatible with device!");
                        NSValue* archValue = [NSValue value:&arch withObjCType:@encode(struct fat_arch)];
                        [stripHeaders addObject:archValue];
                        break;
                    }
                    case COMPATIBLE_STRIP: {
                        DEBUG("arch compatible with device, but strip");
                        
                        NSString* stripPath = strip_arch(binaryPath, arch->cpusubtype);
                        if (stripPath == NULL) {
                            ERROR(@"error stripping binary!");
                            *error = @"Could not strip binary";
                            goto c_err;
                            break;
                        }
                        
                        FILE* stripBinary = fopen([stripPath UTF8String], "r+");
                        
                        if (!dump_binary(stripBinary, newbinary, CFSwapInt32(arch->offset), stripPath, finalPath)) {
                            // Dumping failed
                            
                            DebugLog(@"Cannot crack stripped arm%u portion of binary.", CFSwapInt32(arch->cpusubtype));
                            
                            //*error = @"Cannot crack unswapped portion of binary.";
                            fclose(newbinary); // close the new binary stream
                            fclose(oldbinary); // close the old binary stream
                            [[NSFileManager defaultManager] removeItemAtPath:finalPath error:NULL]; // delete the new binary
                            return NO;
                        }
                        swap_back(stripPath, baseDirectory, baseName);
                        compatibleArch = arch;
                        break;
                    }
                    case COMPATIBLE_SWAP: {
                        DEBUG("arch compatible with device, but swap");
                        
                        NSString* stripPath = swap_arch(binaryPath, baseDirectory, baseName, arch->cpusubtype);
                        if (stripPath == NULL) {
                            ERROR(@"error stripping binary!");
                            *error = @"Could not strip binary";
                            goto c_err;
                            break;
                        }
                        
                        FILE* stripBinary = fopen([stripPath UTF8String], "r+");
                        
                        if (!dump_binary(stripBinary, newbinary, CFSwapInt32(arch->offset), stripPath, finalPath)) {
                            // Dumping failed
                            
                            DebugLog(@"Cannot crack stripped arm%u portion of binary.", CFSwapInt32(arch->cpusubtype));
                            
                            //*error = @"Cannot crack unswapped portion of binary.";
                            fclose(newbinary); // close the new binary stream
                            fclose(oldbinary); // close the old binary stream
                            [[NSFileManager defaultManager] removeItemAtPath:finalPath error:NULL]; // delete the new binary
                            return NO;
                        }
                        swap_back(stripPath, baseDirectory, baseName);
                        
                        compatibleArch = arch;
                        break;
                    }
                }
                if ((archCount - [stripHeaders count]) == 1) {
                    DEBUG("only one architecture left!? strip");
                    if (!lipoBinary(newbinary, finalPath, compatibleArch)) {
                        ERROR(@"Could not lipo binary");
                        *error = @"Could not lipo binary";
                        goto c_err;
                        break;
                    }
                    goto c_complete;
                }
                arch++;
            }
            
            //strip headers
            if ([stripHeaders count] > 0) {
                for (NSValue* obj in stripHeaders) {
                    struct fat_arch* stripArch;
                    [obj getValue:&stripArch];
                    removeArchitecture(finalPath, stripArch);
                }
            }
            break;
        }
    }


    
c_complete:
    fclose(newbinary); // close the new binary stream
	fclose(oldbinary); // close the old binary stream
	return finalPath; // return cracked binary path
	
c_err:
	fclose(newbinary); // close the new binary stream
	fclose(oldbinary); // close the old binary stream
	[[NSFileManager defaultManager] removeItemAtPath:finalPath error:NULL]; // delete the new binary
	return nil;
}


NSString * genRandStringLength(int len) {
	NSMutableString *randomString = [NSMutableString stringWithCapacity: len];
	NSString *letters = @"abcdef0123456789";
	
	for (int i=0; i<len; i++) {
		[randomString appendFormat: @"%c", [letters characterAtIndex: arc4random()%[letters length]]];
	}
	
	return randomString;
}

uint32_t get_local_cputype() {
    const struct mach_header *header = _dyld_get_image_header(0);
    uint32_t cputype = (uint32_t)header->cputype;
    //DEBUG("header header header yo %u %u", header->cpusubtype, cputype);
    
    DEBUG("######## CPU INFO ########");
    if (cputype == 12) {
       DEBUG("local_cputype: 32bit");
        return CPUTYPE_32;
    }
    else {
        DEBUG("local_cputype: 64bit");
        return CPUTYPE_64;
    }
    return -1;
    
}

uint32_t get_local_cpusubtype() {
    //Name of image (includes full path)
    const struct mach_header *header = _dyld_get_image_header(0);
    DEBUG("header header header yo %u %u", header->cpusubtype, header->cputype);
    return header->cpusubtype;
}


