-- Keep demonstrations for one release. Older releases use CHANGELOG.md only.
-- Edit description text between [=[ and ]=]; apostrophes and quotation marks are safe inside.
return {
  version = '0.4.0',
  features = {
    {
      title = 'Spectrum Analyser',
      card_title = 'Spectrum\nAnalyser',
      overview = [=[See the frequency balance of your sounds and isolate the parts you want to hear.]=],
      topics = {
        { id = 'overview', title = 'Overview', renderer = 'spectrum',
          body = [=[yb-Reference now has a high-quality frequency spectrum analyser. Use it to see the frequency balance of your audio in real time.]=] },
        { id = 'monitor_helper', title = 'Monitor FX Helper', renderer = 'helper',
          body = [=[A small Monitor FX plug-in lets the spectrum analyser work with audio from both yb-Reference and Reaper. It is added automatically on first launch, before other Monitor FX so analysis happens before their processing.]=] },
        { id = 'peaks', title = 'Hold Peaks', renderer = 'spectrum',
          body = [=[Hover over the graph and keep the pointer still to hold its peaks. This keeps brief peaks visible for inspection; move away to release them.]=] },
        { id = 'filter_bar', title = 'Filter Bar', renderer = 'spectrum',
          body = [=[Select a filter band or drag its boundaries to hear a frequency range on its own. Open the bar’s Settings to customise the filters and spectrum display.]=] },
      },
    },
    {
      title = 'Improved Waveform',
      card_title = 'Improved\nWaveform',
      overview = [=[Waveform displays are now more detailed and allow you to zoom and scroll.]=],
      topics = {
        { id = 'waveform_navigation', title = 'Navigate & Zoom',
          body = [=[Drag the time ruler sideways to navigate and vertically to zoom. Enlarge quiet waveforms by adjusting the right-hand rail for a closer look without changing playback volume.]=] },
        { id = 'waveform_detail', title = 'Closer Detail',
          body = [=[Zoom further in with the time ruler to reveal individual samples. This lets you inspect the fine shape of transients and other short details.]=] },
      },
    },
    {
      title = 'Panel Layout',
      card_title = 'Panel\nLayout',
      overview = [=[The waveform and spectrum automatically rearrange as you resize the window.]=],
      topics = {
        { id = 'layout_auto', title = 'Auto Layout',
          body = [=[The panels automatically rearrange themselves when you resize the window. To force either arrangement, choose Side by Side or Stacked in Settings → Appearance. Small windows still show one panel.]=] },
        { id = 'layout_swap', title = 'Swap Panels',
          body = [=[Hover over the divider and click the swap button to switch the panel positions.]=] },
      },
    },
    {
      title = 'UI Animations',
      card_title = 'UI\nAnimations',
      overview = [=[New UI animations for a more polished visual experience.]=],
      topics = {
        { id = 'buttons_feedback', title = 'Everyday Controls',
          body = [=[yb-Reference now has new interaction animations throughout for a more polished feel. Turn them off in Settings → Appearance if you don't want them.]=] },
      },
    },
  },
}
