//
//  DatabaseEncryption_Tests.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 2/16/15.
//
//

#import "CBLTestCase.h"
#import "CBL_SQLiteStorage.h"
#import "CBL_Attachment.h"
#import "CBL_BlobStore.h"


@interface CBL_BlobStore ()
- (NSString*) rawPathForKey: (CBLBlobKey)key;
@end



@interface DatabaseEncryption_Tests : CBLTestCaseWithDB
@end


@implementation DatabaseEncryption_Tests
{
    CBLDatabase* seekrit;
}


- (void) setUp {
    [super setUp];
    CBLEnableMockEncryption = YES;
}


- (void) tearDown {
    CBLEnableMockEncryption = NO;
    [super tearDown];
}


- (void) test01_EncryptionFailsGracefully {
    CBLEnableMockEncryption = NO;
    Assert([dbmgr registerEncryptionKey: @"123456" forDatabaseNamed: @"seekrit"]);
    [self allowWarningsIn:^{
        NSError* error;
        seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
        if (seekrit == nil)
            AssertEq(error.code, 501 /*Not Implemented*/);
    }];
}


- (void) test02_UnEncryptedDB {
    // Create unencrypted DB:
    NSError* error;
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to create encrypted db: %@", error);
    [self createDocumentWithProperties: @{@"answer": @42} inDatabase: seekrit];
    Assert([seekrit close: NULL]);

    // Try to reopen with password (fails):
    [self allowWarningsIn:^{
        [dbmgr registerEncryptionKey: @"wrong" forDatabaseNamed: @"seekrit"];
        NSError* error;
        seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
        AssertNil(seekrit, @"Shouldn't have been able to reopen encrypted db with wrong password");
        AssertEq(error.code, 401);
    }];

    // Reopen with no password:
    [dbmgr registerEncryptionKey: nil forDatabaseNamed: @"seekrit"];
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to reopen encrypted db: %@", error);
    AssertEq(seekrit.documentCount, 1u);
}


- (void) test03_EncryptedDB {
    // Create encrypted DB:
    NSError* error;
    [dbmgr registerEncryptionKey: @"letmein" forDatabaseNamed: @"seekrit"];
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to create encrypted db: %@", error);
    [self createDocumentWithProperties: @{@"answer": @42} inDatabase: seekrit];
    Assert([seekrit close: NULL]);

    // Try to reopen without the password (fails):
    [self allowWarningsIn:^{
        [dbmgr registerEncryptionKey: nil forDatabaseNamed: @"seekrit"];
        NSError* error;
        seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
        AssertNil(seekrit, @"Shouldn't have been able to reopen encrypted db w/o password");
        AssertEq(error.code, 401);

        // Try to reopen with wrong password (fails):
        [dbmgr registerEncryptionKey: @"wrong" forDatabaseNamed: @"seekrit"];
        seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
        AssertNil(seekrit, @"Shouldn't have been able to reopen encrypted db with wrong password");
        AssertEq(error.code, 401);
    }];

    // Reopen with correct password:
    [dbmgr registerEncryptionKey: @"letmein" forDatabaseNamed: @"seekrit"];
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to reopen encrypted db: %@", error);
    AssertEq(seekrit.documentCount, 1u);
}


- (void) test04_DeleteEncryptedDB {
    // Create encrypted DB:
    __block NSError* error;
    [dbmgr registerEncryptionKey: @"letmein" forDatabaseNamed: @"seekrit"];
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to create encrypted db: %@", error);
    [self createDocumentWithProperties: @{@"answer": @42} inDatabase: seekrit];

    // Delete db; this also unregisters its password:
    Assert([seekrit deleteDatabase: NULL], @"Couldn't delete database");

    // Re-create database:
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to re-create formerly encrypted db: %@", error);
    AssertEq(seekrit.documentCount, 0u);
    Assert([seekrit close: NULL]);

    // Make sure it doesn't need a password now:
    [dbmgr registerEncryptionKey: nil forDatabaseNamed: @"seekrit"];
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    AssertEq(seekrit.documentCount, 0u);
    Assert([seekrit close: NULL]);

    // Make sure old password doesn't work:
    [dbmgr registerEncryptionKey: @"letmein" forDatabaseNamed: @"seekrit"];
    [self allowWarningsIn:^{
        seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    }];
    AssertNil(seekrit, @"Password opened unencrypted db!");
    AssertEq(error.code, 401);
}


- (void) test05_CompactEncryptedDB {
    // Create encrypted DB:
    __block NSError* error;
    [dbmgr registerEncryptionKey: @"letmein" forDatabaseNamed: @"seekrit"];
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to create encrypted db: %@", error);

    // Create a doc and then update it:
    CBLDocument* doc = [self createDocumentWithProperties: @{@"answer": @42} inDatabase: seekrit];
    [doc update: ^BOOL(CBLUnsavedRevision *rev) {
        rev[@"foo" ] = @84;
        return YES;
    } error: NULL];

    // Compact:
    Log(@"//// Compacting");
    Assert([seekrit compact: &error], @"Compaction failed: %@", error);

    // Add a document:
    [doc update:^BOOL(CBLUnsavedRevision *rev) {
        rev[@"foo"] = @85;
        return YES;
    } error: NULL];

    // Close and re-open:
    Assert([seekrit close: &error], @"Close failed: %@", error);
    Log(@"//// Reopening database");
    [dbmgr registerEncryptionKey: @"letmein" forDatabaseNamed: @"seekrit"];
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to reopen encrypted db: %@", error);
    AssertEq(seekrit.documentCount, 1u);
}


- (void) test06_Keychain {
#if !TARGET_OS_IPHONE
    // Create encrypted DB:
    NSError* error;
    Assert([dbmgr encryptDatabaseNamed: @"seekrit"], @"encryptDatabaseNamed failed");
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to create encrypted db: %@", error);
    [self createDocumentWithProperties: @{@"answer": @42} inDatabase: seekrit];
    Assert([seekrit close: NULL]);

    // Try to reopen without the password (fails):
    [self allowWarningsIn:^{
        [dbmgr registerEncryptionKey: nil forDatabaseNamed: @"seekrit"];
        NSError* error;
        seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
        AssertNil(seekrit, @"Shouldn't have been able to reopen encrypted db w/o password");
        AssertEq(error.code, 401);

        // Try to reopen with wrong password (fails):
        [dbmgr registerEncryptionKey: @"wrong" forDatabaseNamed: @"seekrit"];
        seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
        AssertNil(seekrit, @"Shouldn't have been able to reopen encrypted db with wrong password");
        AssertEq(error.code, 401);
    }];

    // Reopen with correct password:
    Assert([dbmgr encryptDatabaseNamed: @"seekrit"], @"encryptDatabaseNamed failed");
    seekrit = [dbmgr databaseNamed: @"seekrit" error: &error];
    Assert(seekrit, @"Failed to reopen encrypted db: %@", error);
    AssertEq(seekrit.documentCount, 1u);
#endif
}


- (void) test07_EncryptedAttachments {
    [self _testEncryptedAttachmentsWithKey: @"letmein"];
}

- (void) _testEncryptedAttachmentsWithKey: (NSString*)key {
    [dbmgr registerEncryptionKey: key forDatabaseNamed: @"seekrit"];
    seekrit = [dbmgr databaseNamed: @"seekrit" error: NULL];
    Assert(seekrit);

    // Save a doc with an attachment:
    CBLDocument* doc = [seekrit documentWithID: @"att"];
    NSData* body = [@"This is a test attachment!" dataUsingEncoding: NSUTF8StringEncoding];
    CBLUnsavedRevision *rev = [doc newRevision];
    [rev setAttachmentNamed: @"att.txt" withContentType: @"text/plain; charset=utf-8" content:body];
    NSError* error;
    CBLSavedRevision* savedRev = [rev save: &error];
    Assert(savedRev, @"Saving doc failed: %@", error);

    // Read the raw attachment file and make sure it's not cleartext:
    NSString* digest = savedRev[@"_attachments"][@"att.txt"][@"digest"];
    Assert(digest);
    CBLBlobKey attKey;
    Assert([CBL_Attachment digest: digest toBlobKey: &attKey]);
    NSString* path = [seekrit.attachmentStore rawPathForKey: attKey];
    NSData* raw = [NSData dataWithContentsOfFile: path];
    Assert(raw != nil);
    if (key)
        Assert(![raw isEqual: body], @"Oops, attachment was not encrypted");
    else
        Assert([raw isEqual: body], @"Oops, attachment was encrypted");
}


- (void) test08_AddKey      { [self rekeyUsingOldKey: nil        newKey: @"letmein"]; }
- (void) test09_Rekey       { [self rekeyUsingOldKey: @"letmein" newKey: @"letmeout"]; }
- (void) test10_RemoveKey   { [self rekeyUsingOldKey: @"letmein" newKey: nil]; }

- (void) rekeyUsingOldKey: (NSString*)oldKey newKey: (NSString*)newKey {
    // First run the encrypted-attachments test to populate the db:
    Log(@"Creating database with key '%@'", oldKey);
    [self _testEncryptedAttachmentsWithKey: oldKey];

    // Create a view and some documents:
    [seekrit inTransaction:^BOOL{
        for (unsigned i=0; i<100; i++) {
            @autoreleasepool {
                NSDictionary* properties = @{@"testName": @"testDatabase", @"sequence": @(i)};
                [self createDocumentWithProperties: properties inDatabase:seekrit];
            }
        }
        return YES;
    }];
    
    CBLView* view = [seekrit viewNamed: @"vu"];
    [view setMapBlock: MAPBLOCK({
        if(doc[@"sequence"] != nil) {
            emit(doc[@"sequence"], nil);
        }
    }) version: @"1"];
    CBLQuery* query = [view createQuery];
    NSError* error;
    AssertEq([[query run: &error] count], 100u);

    Log(@"Re-keying database with new key '%@'", newKey);
    Assert([seekrit changeEncryptionKey: newKey error: &error],
           @"Error changing encryption key: %@", error);

    // Close & reopen seekrit:
    NSString* dbName = seekrit.name;
    Assert([seekrit close: &error], @"Couldn't close seekrit: %@", error);
    seekrit = nil;
    Log(@"Re-opening database with new key '%@'", newKey);
    Assert([dbmgr registerEncryptionKey: newKey forDatabaseNamed: @"seekrit"]);
    CBLDatabase* seekrit2 = [dbmgr databaseNamed: dbName error: &error];
    Assert(seekrit2, @"Couldn't reopen seekrit: %@", error);
    Assert(seekrit2 != seekrit, @"-reopenTestDB couldn't make a new instance");
    seekrit = seekrit2;

    // Check the document and its attachment:
    CBLSavedRevision* savedRev = [seekrit documentWithID: @"att"].currentRevision;
    Assert(savedRev);
    CBLAttachment* att = [savedRev attachmentNamed: @"att.txt"];
    Assert(att);
    NSData* body = [@"This is a test attachment!" dataUsingEncoding: NSUTF8StringEncoding];
    AssertEqual(att.content, body);

    // Check that the view survived:
    view = [seekrit existingViewNamed:@"vu"];
    Assert(view != nil);
    
    // Need to reset the map block since it was destroyed when the database closed
    [view setMapBlock: MAPBLOCK({
        if(doc[@"sequence"] != nil) {
            emit(doc[@"sequence"], nil);
        }
    }) version: @"1"];
    query = [view createQuery];
    query.indexUpdateMode = kCBLUpdateIndexNever; // Make sure that the query doesn't generate new results
    
    AssertEq([[query run: &error] count], 100u);
}


@end
