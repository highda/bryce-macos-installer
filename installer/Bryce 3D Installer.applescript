-- Bryce 3D Installer
-- Drag-and-drop front end for make-bryce-app.zsh (bundled in Contents/Resources).
-- Build the app with build-installer.zsh.

use AppleScript version "2.4"
use scripting additions

property appName : "Bryce 3D Installer"

on run
	try
		set choice to button returned of (display dialog "This installs Bryce 3D as a Mac app from your own Bryce 3D CD (Windows edition)." & return & return & "Drag your CD image onto this installer's icon, or choose it now." with title appName buttons {"Cancel", "Choose CD or Folder…", "Choose CD Image…"} default button 3 cancel button 1 with icon note)
		if choice is "Choose CD Image…" then
			set src to choose file with prompt "Choose your Bryce 3D CD image (.iso, .cdr, .dmg or .toast):"
		else
			set src to choose folder with prompt "Choose the Bryce 3D CD, or a folder with a copy of it:" default location (POSIX file "/Volumes")
		end if
	on error number -128
		return
	end try
	install(src)
end run

on open droppedItems
	install(item 1 of droppedItems)
end open

on install(src)
	set srcPath to POSIX path of src
	set engine to POSIX path of (path to resource "make-bryce-app.zsh")
	set logPath to (POSIX path of (path to library folder from user domain)) & "Logs/Bryce 3D Installer.log"

	try
		-- Rosetta 2 (Apple Silicon only)
		if (do shell script "uname -m") is "arm64" then
			try
				do shell script "/usr/bin/arch -x86_64 /usr/bin/true"
			on error
				display dialog "Bryce 3D needs Rosetta 2, Apple's free translator for Intel apps." & return & return & "Install it now? macOS will ask for your password." with title appName buttons {"Cancel", "Install Rosetta"} default button 2 cancel button 1 with icon caution
				do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges
			end try
		end if

		-- An existing installation gets replaced.
		set existing to do shell script "for d in /Applications \"$HOME/Applications\"; do if [ -d \"$d/Bryce 3D.app\" ]; then echo \"$d/Bryce 3D.app\"; break; fi; done"
		if existing is not "" then
			display dialog "Bryce 3D is already installed:" & return & existing & return & return & "It will be replaced. Your scenes in Documents › Bryce 3D are kept." with title appName buttons {"Cancel", "Replace"} default button 2 cancel button 1 with icon caution
		end if

		set serialNumber to text returned of (display dialog "During installation, Bryce 3D opens its registration window once and asks for your name, organisation and serial number." & return & return & "Optional: type your serial here and it will be on the clipboard, ready to paste with ⌘V." default answer "" with title appName buttons {"Cancel", "Install"} default button 2 cancel button 1 with icon note)
	on error errText number errNum
		if errNum is -128 then return
		display dialog errText with title appName buttons {"OK"} default button 1 with icon stop
		return
	end try

	set progPath to do shell script "mktemp -t bryce-progress"
	set pid to do shell script "BRYCE_SERIAL=" & quoted form of serialNumber & " /bin/zsh " & quoted form of engine & " " & quoted form of srcPath & " --progress " & quoted form of progPath & " > " & quoted form of logPath & " 2>&1 & echo $!"

	set progress total steps to 8
	set progress completed steps to 0
	set progress description to "Installing Bryce 3D…"
	set progress additional description to "Starting…"

	set seen to 0
	set outcome to ""
	set destPath to ""
	set errMsg to "The installation stopped unexpectedly."
	set finished to false
	try
		repeat
			delay 0.5
			if (do shell script "kill -0 " & pid & " 2>/dev/null && echo running || echo stopped") is "stopped" then set finished to true
			set newText to do shell script "tail -n +" & (seen + 1) & " " & quoted form of progPath
			repeat with para in paragraphs of newText
				set ln to para as text
				if ln is not "" then
					set seen to seen + 1
					if ln starts with "STEP " then
						set stepInfo to text 6 thru -1 of ln
						set sp to offset of " " in stepInfo
						set frac to text 1 thru (sp - 1) of stepInfo
						set stepNumber to (text 1 thru ((offset of "/" in frac) - 1) of frac) as integer
						set progress completed steps to stepNumber - 1
						set progress additional description to "Step " & frac & ": " & (text (sp + 1) thru -1 of stepInfo)
					else if ln is "REGISTER" then
						set progress additional description to "Bryce 3D is asking for your registration: enter your name and serial in its window, then click OK. (Can't see it? Click the Wine icon in the Dock.)"
					else if ln starts with "DONE " then
						set outcome to "done"
						set destPath to text 6 thru -1 of ln
					else if ln starts with "ERROR " then
						set outcome to "error"
						set errMsg to text 7 thru -1 of ln
					end if
				end if
			end repeat
			if outcome is not "" or finished then exit repeat
		end repeat
	on error errText number errNum
		-- Stop button in the progress window (-128) or an unexpected error:
		-- never leave the build running without a window.
		do shell script "pkill -TERM -P " & pid & " 2>/dev/null; kill -TERM " & pid & " 2>/dev/null; true"
		if errNum is not -128 then display dialog "The installer hit an unexpected error and stopped." & return & return & errText with title appName buttons {"OK"} default button 1 with icon stop
		return
	end try
	do shell script "rm -f " & quoted form of progPath

	if outcome is "done" then
		set progress completed steps to 8
		set progress additional description to "Done"
		set answer to button returned of (display dialog "Bryce 3D is installed:" & return & destPath & return & return & "Scenes and renders are saved in Documents › Bryce 3D. The CD's libraries and sample scenes are on drive D: inside Bryce." with title appName buttons {"Show in Finder", "Open Bryce 3D"} default button 2 with icon note)
		if answer is "Open Bryce 3D" then
			do shell script "open " & quoted form of destPath
		else
			do shell script "open -R " & quoted form of destPath
		end if
	else
		set answer to button returned of (display dialog "Bryce 3D could not be installed." & return & return & errMsg with title appName buttons {"Show Log", "OK"} default button 2 with icon stop)
		if answer is "Show Log" then do shell script "open -a Console " & quoted form of logPath
	end if
end install
