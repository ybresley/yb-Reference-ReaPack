# yb-Reference — private beta

yb-Reference is a floating or dockable reference library for REAPER. It keeps your chosen reference sounds close, previews them through Monitor FX, and lets you switch between your project and a selected reference with one hotkey.

This is an invite-only Windows beta. Please do not share the installation address or package files.

## Before you install

You need:

- Windows
- REAPER
- [ReaPack](https://reapack.com/)
- The free **SWS Extension** and **ReaImGui** packages, installed through ReaPack

Use a current version of REAPER, ReaPack, SWS and ReaImGui. Restart REAPER after installing or updating an extension.

## Install yb-Reference

1. In REAPER, choose **Extensions → ReaPack → Import repositories…**
2. Paste this address:

   ```text
   https://raw.githubusercontent.com/ybresley/yb-Reference-releases/main/index.xml
   ```

3. Choose **Extensions → ReaPack → Browse packages…**
4. Search for **yb-Reference**.
5. Select **yb-Reference**, choose **Install**, then select **Apply**.
6. Restart REAPER.
7. Choose **Actions → Show action list…**, search for **yb-Reference.lua**, and run it.

You can also add the main tool to a toolbar or give it a shortcut from REAPER's Action List.

## Set the reference-mode hotkey

1. Choose **Actions → Show action list…**
2. Search for **yb-Reference_ToggleReferenceMode.lua**. Searching for **ToggleReferenceMode** is enough.
3. Select the action and choose **Add…** beside the shortcut list.
4. Press the shortcut you want to use and confirm it.

The hotkey works while the main yb-Reference window is open. Pressing it while the tool is closed does nothing.

## Your first reference

The first launch offers a short walkthrough. You can replay it later from **Settings → Help**.

1. Save your REAPER project. Project references need a saved project folder.
2. Open **Library** in yb-Reference.
3. Select **Add sounds**, or drag audio files into the Library.
4. Drag a Library sound onto the main yb-Reference window to pin it to the project.
   - You can also drag an audio file directly onto the main window to add and pin it in one step.
5. Choose the pinned reference from the name control in the main window.
6. Select **R**, or use your new hotkey, to turn reference mode on.
   - Your project is silenced as soon as reference mode turns on.
   - Press Play in REAPER to hear the selected reference instead.
7. Select **R** or press the hotkey again to restore normal project playback.

Files added to the Library are copied into a managed library folder. Your original files are not moved or changed. Pinned references are also copied into a `References` folder beside the saved REAPER project so the project keeps its own copy.

## Useful basics

- Click a Library sound to audition it. Auto-audition can be turned off with the ear button.
- Click the waveform to play from that point.
- Drag the start and end handles to choose the part that plays and travels to the timeline.
- Drag a sound from yb-Reference onto REAPER's arrange view to create an item.
- Use the **◎** loudness panel to inspect measurements or set the sound's trim to a target.
- Use **Settings → Feedback** to send a bug report or idea.

## Known beta limitations

- **Windows only.** macOS and Linux are not supported in this beta.
- **Keep one copy open.** Do not run yb-Reference a second time while it is already open. If you are unsure, close the visible copy before running it again.
- **Mono and stereo audio only.** Files with more than two channels are skipped rather than changed.
- **Measurements may take a moment.** New or existing sounds can show `…` while their waveform and loudness values are being measured. The sounds remain playable while this finishes. Very long files take longer.
- **A missing Library folder stops startup deliberately.** If your Library is on a disconnected drive or unavailable network location, reconnect it and run the tool again. The tool will not replace it with an empty library.
- **Deleting has no Restore button yet.** Deleted audio and its information are moved into the Library's `Trash` folder, but restoration is currently a manual operation. Contact Yoni before changing anything in that folder.
- **Loudness can differ from the SWS meter by roughly 0.5–1.7 dB.** yb-Reference uses REAPER's own file measurement, matching REAPER's render/export results. This known difference is not lost or damaged audio.
- **Pause briefly when dragging across windows.** When dragging a sound from yb-Reference to REAPER's arrange view, keep holding for about half a second after crossing into REAPER before releasing it.

## Feedback and privacy

Open the gear button, choose **Feedback**, type your message, and select **Send**. Adding your email is optional.

A report contains only:

- Your message
- Your optional email address
- The yb-Reference version
- The REAPER version
- Whether yb-Reference was installed through ReaPack

It does not send audio, file paths, project names or a machine identifier. Reports go to Yoni's private Google Sheet. If sending fails, your message stays in the panel and is copied to the Windows clipboard so you can email it instead.

Thank you for testing yb-Reference. Honest reports about anything confusing, unreliable or awkward are more useful than polished feedback.
