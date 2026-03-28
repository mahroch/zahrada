#!/bin/bash
# Export Apple Notes "Zahrada" folder to git repo
# Runs periodically via LaunchAgent

REPO_DIR="/Users/maros/Library/Mobile Documents/iCloud~md~obsidian/Documents/Zahrada"
NOTESDB="/Users/maros/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
MEDIA_BASE="/Users/maros/Library/Group Containers/group.com.apple.notes/Accounts"

# Step 1: Export all notes via AppleScript
osascript <<'APPLESCRIPT'
set exportBase to "/Users/maros/Library/Mobile Documents/iCloud~md~obsidian/Documents/Zahrada/"

tell application "Notes"
    -- Export notes directly in Zahrada
    repeat with f in folders
        if name of f is "Zahrada" then
            do shell script "mkdir -p " & quoted form of exportBase
            repeat with n in notes of f
                my exportNote(n, exportBase)
            end repeat
        end if
    end repeat

    -- Export subfolders of Zahrada
    repeat with f in folders
        try
            set cID to id of (container of f)
            repeat with f2 in folders
                if id of f2 is cID and name of f2 is "Zahrada" then
                    set subPath to exportBase & name of f & "/"
                    do shell script "mkdir -p " & quoted form of subPath
                    repeat with n in notes of f
                        my exportNote(n, subPath)
                    end repeat

                    -- Export sub-subfolders (e.g. Zvierata/Sliepky)
                    set subID to id of f
                    repeat with f3 in folders
                        try
                            set cID3 to id of (container of f3)
                            repeat with f4 in folders
                                if id of f4 is cID3 and id of f4 is subID then
                                    set subSubPath to subPath & name of f3 & "/"
                                    do shell script "mkdir -p " & quoted form of subSubPath
                                    repeat with n3 in notes of f3
                                        my exportNote(n3, subSubPath)
                                    end repeat
                                end if
                            end repeat
                        end try
                    end repeat
                end if
            end repeat
        end try
    end repeat
end tell

on exportNote(n, folderPath)
    tell application "Notes"
        set noteName to name of n
        set noteContent to body of n
    end tell
    set safeName to do shell script "echo " & quoted form of noteName & " | sed 's/[/:*?\"<>|\\\\]/_/g'"
    set filePath to folderPath & safeName & ".html"
    set fileRef to open for access (POSIX file filePath) with write permission
    set eof fileRef to 0
    write noteContent to fileRef as «class utf8»
    close access fileRef
end exportNote
APPLESCRIPT

# Step 2: Copy image attachments from Apple Notes database
if [ -f "$NOTESDB" ]; then
    # Get folder PKs for Zahrada and all its descendants
    FOLDER_DATA=$(sqlite3 "$NOTESDB" "
        SELECT Z_PK, ZTITLE2, ZPARENT
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZFOLDERTYPE IS NOT NULL
          AND ZTITLE2 IS NOT NULL;
    ")

    # Find Zahrada PK
    ZAHRADA_PK=$(echo "$FOLDER_DATA" | grep "|Zahrada|" | head -1 | cut -d'|' -f1)

    if [ -n "$ZAHRADA_PK" ]; then
        # Get image attachments for notes in Zahrada and subfolders
        sqlite3 -separator '|' "$NOTESDB" "
            WITH RECURSIVE zahrada_folders(pk) AS (
                SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = $ZAHRADA_PK
                UNION ALL
                SELECT c.Z_PK FROM ZICCLOUDSYNCINGOBJECT c
                JOIN zahrada_folders p ON c.ZPARENT = p.pk
                WHERE c.ZFOLDERTYPE IS NOT NULL
            )
            SELECT
                n.ZTITLE1,
                folder.ZTITLE2,
                parent.ZTITLE2,
                media.ZIDENTIFIER,
                media.ZFILENAME
            FROM ZICCLOUDSYNCINGOBJECT n
            JOIN ZICCLOUDSYNCINGOBJECT att ON att.ZNOTE = n.Z_PK
            JOIN ZICCLOUDSYNCINGOBJECT media ON att.ZMEDIA = media.Z_PK
            JOIN ZICCLOUDSYNCINGOBJECT folder ON n.ZFOLDER = folder.Z_PK
            LEFT JOIN ZICCLOUDSYNCINGOBJECT parent ON folder.ZPARENT = parent.Z_PK
            WHERE n.ZFOLDER IN (SELECT pk FROM zahrada_folders)
              AND att.ZTYPEUTI LIKE 'public.%'
              AND att.ZTYPEUTI NOT LIKE '%table%'
              AND media.ZFILENAME IS NOT NULL;
        " | while IFS='|' read -r title folder_name parent_name media_id filename; do
            # Determine target directory
            if [ "$folder_name" = "Zahrada" ]; then
                target_dir="$REPO_DIR"
            elif [ "$parent_name" = "Zahrada" ]; then
                target_dir="$REPO_DIR/$folder_name"
            else
                target_dir="$REPO_DIR/$parent_name/$folder_name"
            fi

            # Find and copy media file
            media_file=$(find "$MEDIA_BASE" -path "*${media_id}*" -type f 2>/dev/null | head -1)
            if [ -n "$media_file" ] && [ -d "$target_dir" ]; then
                cp -n "$media_file" "$target_dir/$filename" 2>/dev/null
            fi
        done
    fi
fi

# Step 3: Git commit and push
cd "$REPO_DIR" || exit 1
git pull --rebase --autostash origin main 2>/dev/null

if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "vault backup: $(date '+%Y-%m-%d %H:%M:%S')"
    git push origin main
fi
