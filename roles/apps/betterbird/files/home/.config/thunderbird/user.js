// Betterbird account provisioning (applied at every startup).
// Harvested from the live profile on 2026-10-05 — re-harvest after account changes.
// NOTE: prefs below are forced on each launch; UI edits to these keys revert
// at restart unless this file is updated. Runtime noise (filter timestamps,
// server greeting cache) is intentionally excluded.

// Account manager
user_pref("mail.accountmanager.accounts", "account1,account2");
user_pref("mail.accountmanager.defaultaccount", "account1");
user_pref("mail.accountmanager.localfoldersserver", "server3");
user_pref("mail.account.account1.identities", "id1");
user_pref("mail.account.account1.server", "server2");
user_pref("mail.account.account2.server", "server3");
user_pref("mail.account.lastKey", 2);

// Identity
user_pref("mail.identity.id1.doBcc", false);
user_pref("mail.identity.id1.draft_folder", "imap://michel.paronnaud%40phosmachina.com@mail.phosmachina.com/Drafts");
user_pref("mail.identity.id1.drafts_folder_picker_mode", "0");
user_pref("mail.identity.id1.fcc_folder", "imap://michel.paronnaud%40phosmachina.com@mail.phosmachina.com/Sent Items");
user_pref("mail.identity.id1.fcc_folder_picker_mode", "1");
user_pref("mail.identity.id1.fullName", "Michel Paronnaud");
user_pref("mail.identity.id1.reply_on_top", 1);
user_pref("mail.identity.id1.smtpServer", "smtp1");
user_pref("mail.identity.id1.stationery_folder", "imap://michel.paronnaud%40phosmachina.com@mail.phosmachina.com/Templates");
user_pref("mail.identity.id1.tmpl_folder_picker_mode", "0");
user_pref("mail.identity.id1.useremail", "michel.paronnaud@phosmachina.com");
user_pref("mail.identity.id1.valid", true);

// IMAP server: michel.paronnaud@phosmachina.com
user_pref("mail.server.server2.check_new_mail", true);
user_pref("mail.server.server2.hostname", "mail.phosmachina.com");
user_pref("mail.server.server2.login_at_startup", true);
user_pref("mail.server.server2.max_cached_connections", 5);
user_pref("mail.server.server2.moveTargetMode", 1);
user_pref("mail.server.server2.name", "michel.paronnaud@phosmachina.com");
user_pref("mail.server.server2.namespace.personal", "\"\"");
user_pref("mail.server.server2.port", 993);
user_pref("mail.server.server2.socketType", 3);
user_pref("mail.server.server2.spamActionTargetAccount", "imap://michel.paronnaud%40phosmachina.com@mail.phosmachina.com");
user_pref("mail.server.server2.spamActionTargetFolder", "imap://michel.paronnaud%40phosmachina.com@mail.phosmachina.com/Junk Mail");
user_pref("mail.server.server2.storeContractID", "@mozilla.org/msgstore/berkeleystore;1");
user_pref("mail.server.server2.timeout", 29);
user_pref("mail.server.server2.trash_folder_name", "Deleted Items");
user_pref("mail.server.server2.type", "imap");
user_pref("mail.server.server2.userName", "michel.paronnaud@phosmachina.com");

// Local Folders
user_pref("mail.server.server3.hostname", "Local Folders");
user_pref("mail.server.server3.name", "Local Folders");
user_pref("mail.server.server3.spamActionTargetAccount", "mailbox://nobody@Local%20Folders");
user_pref("mail.server.server3.storeContractID", "@mozilla.org/msgstore/berkeleystore;1");
user_pref("mail.server.server3.type", "none");
user_pref("mail.server.server3.userName", "nobody");

// SMTP
user_pref("mail.smtpserver.smtp1.authMethod", 3);
user_pref("mail.smtpserver.smtp1.description", "");
user_pref("mail.smtpserver.smtp1.hostname", "mail.phosmachina.com");
user_pref("mail.smtpserver.smtp1.port", 465);
user_pref("mail.smtpserver.smtp1.try_ssl", 3);
user_pref("mail.smtpserver.smtp1.type", "smtp");
user_pref("mail.smtpserver.smtp1.username", "michel.paronnaud@phosmachina.com");
user_pref("mail.smtpservers", "smtp1");

// Calendar
user_pref("calendar.list.sortOrder", "cf0a0300-dfaa-4068-bfba-6accbbd4ec10");
user_pref("calendar.registry.cf0a0300-dfaa-4068-bfba-6accbbd4ec10.calendar-main-default", true);
user_pref("calendar.registry.cf0a0300-dfaa-4068-bfba-6accbbd4ec10.calendar-main-in-composite", true);
user_pref("calendar.registry.cf0a0300-dfaa-4068-bfba-6accbbd4ec10.disabled", true);
user_pref("calendar.registry.cf0a0300-dfaa-4068-bfba-6accbbd4ec10.name", "Home");
user_pref("calendar.registry.cf0a0300-dfaa-4068-bfba-6accbbd4ec10.type", "storage");
user_pref("calendar.registry.cf0a0300-dfaa-4068-bfba-6accbbd4ec10.uri", "moz-storage-calendar://");
user_pref("calendar.timezone.local", "Europe/Paris");
user_pref("calendar.timezone.useSystemTimezone", true);
