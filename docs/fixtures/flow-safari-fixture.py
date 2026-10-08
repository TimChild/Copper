#!/usr/bin/env python3
"""Synthetic Safari data for Move in's end-to-end checks. No real browsing data.

    docs/fixtures/flow-safari-fixture.py OUTDIR

Writes, under OUTDIR:
  export.zip     Safari's File > Export Browsing Data to File... zip: Bookmarks.html
                 (Favorites, Bookmarks Menu, a loose site, the Reading List),
                 History.json + "History - Work.json" (two profiles), Passwords.csv
                 (2 logins, 1 row without a password, 1 one-time code, 1 note),
                 PaymentCards.json (2 cards) and Extensions.json (1 extension)
  pwonly.zip     an export with only Passwords.csv in it
  direct/        a copy laid out as Safari keeps it: Safari/Bookmarks.plist,
                 Safari/History.db, Container/SafariTabs.db (a window, two named
                 tab groups, two pinned tabs, a private window that is never read)
  expected.json  what each of them holds, for the script to compare against
"""
import json
import os
import plistlib
import sqlite3
import sys
import uuid
import zipfile

out = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)
os.makedirs(out, exist_ok=True)

META = '"metadata":{"browser_name":"Safari","browser_version":"26.0","data_type":"%s","export_time_usec":1791370000000000,"schema_version":1}'

BOOKMARKS_HTML = """<!DOCTYPE NETSCAPE-Bookmark-file-1>
\t<HTML>
\t<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
\t<Title>Bookmarks</Title>
\t<H1>Bookmarks</H1>
\t<DT><H3 FOLDED>Favorites</H3>
\t<DL><p>
\t\t<DT><A HREF="https://fav.safari-fixture.example/">Favourite &amp; Co</A>
\t\t<DT><H3 FOLDED>Work</H3>
\t\t<DL><p>
\t\t\t<DT><A HREF="https://docs.safari-fixture.example/guide">Guide</A>
\t\t\t<DT><A HREF="javascript:alert(1)">Bookmarklet</A>
\t\t</DL><p>
\t</DL><p>
\t<DT><H3 FOLDED>Bookmarks Menu</H3>
\t<DL><p>
\t\t<DT><A HREF="https://menu.safari-fixture.example/">Menu item</A>
\t</DL><p>
\t<DT><A HREF="https://loose.safari-fixture.example/">Loose</A>
\t<DT><H3 FOLDED id="com.apple.ReadingList">Reading List</H3>
\t<DL><p>
\t\t<DT><A HREF="https://read.safari-fixture.example/one">Read one</A>
\t\t<DD>A preview line
\t\t<DT><A HREF="https://read.safari-fixture.example/two">Read two</A>
\t</DL><p>
</HTML>
"""

HISTORY = '{%s,"history":[%s]}' % (META % "history", ",".join([
    '{"url":"https://news.safari-fixture.example/","time_usec":1759800000000000,"title":"News","visits_count":4}',
    '{"url":"https://maps.safari-fixture.example/","time_usec":1759800001000000,"title":"Maps","visits_count":2}',
    '{"url":"https://broken.safari-fixture.example/","time_usec":1759800002000000,"visits_count":1,"latest_visit_was_load_failure":true}',
    '{"url":"file:///Users/someone/page.html","time_usec":1759800003000000,"visits_count":3}',
]))
WORK_HISTORY = '{%s,"history":[%s]}' % (META % "history", ",".join([
    '{"url":"https://work.safari-fixture.example/","time_usec":1759800004000000,"title":"Work","visits_count":3}',
    '{"url":"https://maps.safari-fixture.example/","time_usec":1759800005000000,"title":"Maps at work","visits_count":1}',
]))
PASSWORDS = ("Title,URL,Username,Password,Notes,OTPAuth\r\n"
             "safari-fixture.example (ann),https://login.safari-fixture.example/,ann@safari-fixture.example,fixture-pass-1,a note,\r\n"
             "shop.safari-fixture.example,https://shop.safari-fixture.example/,bob,fixture-pass-2,,otpauth://totp/x?secret=ABC\r\n"
             "nopass.safari-fixture.example,https://nopass.safari-fixture.example/,carol,,,\r\n")
CARDS = '{%s,"payment_cards":[{"card_number":"0000000000000000","card_name":"Test card"},{"card_number":"1111111111111111"}]}' % (META % "payment_cards")
EXTENSIONS = '{%s,"extensions":[{"composed_identifier":"com.example.blocker.extension (AB12CD34EF)","developer_name":"Example","display_name":"Example Blocker"}]}' % (META % "extensions")

def zipped(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in files:
            z.writestr("Safari Export/" + name, text.encode("utf-8"))

zipped(os.path.join(out, "export.zip"), [
    ("Bookmarks.html", BOOKMARKS_HTML),
    ("History.json", HISTORY),
    ("History - Work.json", WORK_HISTORY),
    ("Passwords.csv", PASSWORDS),
    ("PaymentCards.json", CARDS),
    ("Extensions.json", EXTENSIONS),
])
zipped(os.path.join(out, "pwonly.zip"), [("Passwords.csv", PASSWORDS)])

# --- Safari's own files -----------------------------------------------------
library = os.path.join(out, "direct", "Safari")
container = os.path.join(out, "direct", "Container")
os.makedirs(library, exist_ok=True)
os.makedirs(container, exist_ok=True)

def leaf(url, title, reading=False):
    node = {"WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "WebBookmarkUUID": str(uuid.uuid4()),
            "URIDictionary": {"title": title}}
    if reading:
        node["ReadingList"] = {"PreviewText": "preview"}
    return node

def folder(title, children):
    return {"WebBookmarkType": "WebBookmarkTypeList", "Title": title, "WebBookmarkUUID": str(uuid.uuid4()), "Children": children}

with open(os.path.join(library, "Bookmarks.plist"), "wb") as f:
    plistlib.dump({"WebBookmarkType": "WebBookmarkTypeList", "Title": "", "WebBookmarkFileVersion": 1, "Children": [
        {"WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "WebBookmarkIdentifier": "History Bookmark Proxy Identifier"},
        folder("BookmarksBar", [leaf("https://bar.safari-direct.example/", "Bar"),
                                folder("Folder", [leaf("https://deep.safari-direct.example/", "Deep")])]),
        folder("BookmarksMenu", [leaf("https://menu.safari-direct.example/", "Menu")]),
        folder("com.apple.ReadingList", [leaf("https://read.safari-direct.example/1", "One", True),
                                         leaf("https://read.safari-direct.example/2", "Two", True),
                                         leaf("https://read.safari-direct.example/3", "Three", True)]),
        leaf("https://top.safari-direct.example/", "Top"),
    ]}, f, fmt=plistlib.FMT_BINARY)

AUGUST = 807278400.0  # 2026-08-01 on the Core Data clock
db = sqlite3.connect(os.path.join(library, "History.db"))
db.executescript("""
CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT,url TEXT NOT NULL UNIQUE,domain_expansion TEXT NULL,visit_count INTEGER NOT NULL,daily_visit_counts BLOB NOT NULL,weekly_visit_counts BLOB NULL,autocomplete_triggers BLOB NULL,should_recompute_derived_visit_counts INTEGER NOT NULL,visit_count_score INTEGER NOT NULL,status_code INTEGER NOT NULL DEFAULT 0);
CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT,history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,visit_time REAL NOT NULL,title TEXT NULL,load_successful BOOLEAN NOT NULL DEFAULT 1,http_non_get BOOLEAN NOT NULL DEFAULT 0,synthesized BOOLEAN NOT NULL DEFAULT 0,redirect_source INTEGER NULL UNIQUE REFERENCES history_visits(id) ON DELETE CASCADE,redirect_destination INTEGER NULL UNIQUE REFERENCES history_visits(id) ON DELETE CASCADE,origin INTEGER NOT NULL DEFAULT 0,generation INTEGER NOT NULL DEFAULT 0,attributes INTEGER NOT NULL DEFAULT 0,score INTEGER NOT NULL DEFAULT 0);
""")
for i, (url, count, title) in enumerate([("https://news.safari-direct.example/", 9, "Direct news"),
                                         ("https://docs.safari-direct.example/", 3, "Direct docs"),
                                         ("https://shop.safari-direct.example/", 1, "Direct shop"),
                                         ("favorites://", 2, "Favorites")], start=1):
    db.execute("INSERT INTO history_items (id, url, visit_count, daily_visit_counts, should_recompute_derived_visit_counts, visit_count_score) VALUES (?, ?, ?, x'00', 0, 0)", (i, url, count))
    db.execute("INSERT INTO history_visits (history_item, visit_time, title) VALUES (?, ?, ?)", (i, AUGUST + i * 60, title))
db.commit()
db.close()

tabs = sqlite3.connect(os.path.join(container, "SafariTabs.db"))
tabs.executescript("""
CREATE TABLE bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT,special_id INTEGER DEFAULT 0,parent INTEGER, type INTEGER,title TEXT,url TEXT COLLATE NOCASE,num_children INTEGER DEFAULT 0,editable INTEGER DEFAULT 1,deletable INTEGER DEFAULT 1,hidden INTEGER DEFAULT 0,hidden_ancestor_count INTEGER DEFAULT 0,order_index INTEGER NOT NULL,external_uuid TEXT UNIQUE,read INTEGER DEFAULT NULL,last_modified REAL DEFAULT NULL,server_id TEXT, sync_key TEXT,sync_data BLOB,added INTEGER DEFAULT 1,deleted INTEGER DEFAULT 0,extra_attributes BLOB DEFAULT NULL,local_attributes BLOB DEFAULT NULL,fetched_icon BOOL DEFAULT 0, icon BLOB DEFAULT NULL,dav_generation INTEGER DEFAULT 0,locally_added BOOL DEFAULT 0,archive_status INTEGER DEFAULT 0,syncable BOOL DEFAULT 1,web_filter_status INTEGER DEFAULT 0, modified_attributes UNSIGNED BIG INT DEFAULT 0, date_closed REAL DEFAULT NULL, last_selected_child INTEGER DEFAULT NULL, subtype INTEGER DEFAULT 0, cookies_uuid TEXT DEFAULT NULL, local_storage_uuid TEXT DEFAULT NULL, session_storage_uuid TEXT DEFAULT NULL, is_marked_for_expiration INTEGER, topic_title TEXT, feature_text TEXT, fetched_feature_text BOOL DEFAULT 0);
CREATE TABLE windows (id INTEGER PRIMARY KEY,active_tab_group_id INTEGER DEFAULT NULL,active_profile_id INTEGER DEFAULT NULL,date_closed REAL DEFAULT NULL,extra_attributes BLOB DEFAULT NULL,is_last_session INTEGER DEFAULT 0,local_tab_group_id INTEGER DEFAULT NULL,private_tab_group_id INTEGER DEFAULT NULL,scene_id TEXT DEFAULT NULL,uuid TEXT NOT NULL UNIQUE,restoration_archive BLOB DEFAULT NULL);
CREATE TABLE windows_tab_groups (id INTEGER PRIMARY KEY,active_tab_id INTEGER DEFAULT NULL,tab_group_id INTEGER NOT NULL,window_id INTEGER NOT NULL,UNIQUE (tab_group_id, window_id));
CREATE TABLE windows_profiles (id INTEGER PRIMARY KEY,active_tab_group_id INTEGER DEFAULT NULL,profile_id INTEGER NOT NULL,window_id INTEGER NOT NULL,UNIQUE (profile_id, window_id));
CREATE TABLE windows_unnamed_tab_groups (id INTEGER PRIMARY KEY,tab_group_id INTEGER NOT NULL,window_id INTEGER NOT NULL,UNIQUE (tab_group_id, window_id));
""")
def bfolder(id, parent, title, uid, subtype=0, hidden=0, order=0):
    tabs.execute("INSERT INTO bookmarks (id, parent, type, subtype, title, external_uuid, hidden, order_index) VALUES (?, ?, 1, ?, ?, ?, ?, ?)",
                 (id, parent, subtype, title, uid, hidden, order))
def tab(id, parent, url, title, order):
    tabs.execute("INSERT INTO bookmarks (id, parent, type, title, url, order_index, external_uuid) VALUES (?, ?, 0, ?, ?, ?, ?)",
                 (id, parent, title, url, order, str(uuid.uuid4())))
bfolder(0, None, "Root", "Root")
bfolder(2, None, "pinned", "pinned", hidden=1)
bfolder(3, None, "privatePinned", "privatePinned", hidden=1)
bfolder(5, 0, "", "DefaultProfile", subtype=2)
bfolder(38, None, "Local", "AAAAAAAA-0000-0000-0000-000000000038", hidden=1)
tab(100, 38, "https://one.safari-direct.example/", "One", 0)
tab(101, 38, "https://two.safari-direct.example/", "Two", 1)
tab(102, 38, "favorites://", "Start Page", 2)
bfolder(39, None, "Private", "AAAAAAAA-0000-0000-0000-000000000039", hidden=1)
tab(110, 39, "https://secret.safari-direct.example/", "Secret", 0)
bfolder(50, 0, "Research", "BBBBBBBB-0000-0000-0000-000000000050", order=2)
tab(140, 50, "https://paper.safari-direct.example/", "Paper", 0)
tab(141, 50, "https://data.safari-direct.example/", "Data", 1)
bfolder(52, 0, "Empty group", "BBBBBBBB-0000-0000-0000-000000000052", order=3)
bfolder(53, 0, "Errands", "BBBBBBBB-0000-0000-0000-000000000053", order=4)
tab(160, 53, "https://errand.safari-direct.example/", "Errand", 0)
tab(170, 2, "https://mail.safari-direct.example/", "Mail", 0)
tab(171, 2, "https://cal.safari-direct.example/", "Calendar", 1)
tab(180, 3, "https://private-pin.safari-direct.example/", "Private pin", 0)
plain = plistlib.dumps({"IsPrivateWindow": False}, fmt=plistlib.FMT_BINARY)
private = plistlib.dumps({"IsPrivateWindow": True}, fmt=plistlib.FMT_BINARY)
tabs.execute("INSERT INTO windows (id, active_tab_group_id, active_profile_id, extra_attributes, is_last_session, local_tab_group_id, uuid) VALUES (1, 38, 5, ?, 1, 38, 'WINDOW-1')", (plain,))
tabs.execute("INSERT INTO windows (id, active_tab_group_id, active_profile_id, extra_attributes, is_last_session, local_tab_group_id, uuid) VALUES (2, 39, 5, ?, 1, 39, 'WINDOW-2')", (private,))
tabs.execute("INSERT INTO windows_tab_groups (tab_group_id, window_id, active_tab_id) VALUES (38, 1, 101)")
tabs.commit()
tabs.close()

json.dump({
    "export": {"bookmarks": 4, "readingList": 2, "places": 3, "passwords": 2, "passwordsSkipped": 1,
               "cards": 2, "extensions": 1, "tabs": 0},
    "direct": {"bookmarks": 4, "readingList": 3, "places": 3},
    "pwonly": {"passwords": 2},
}, open(os.path.join(out, "expected.json"), "w"), indent=1)
print(out)
