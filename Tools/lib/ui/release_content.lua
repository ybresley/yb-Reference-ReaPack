-- Retain one demonstration catalogue, with explicit compatibility for patch releases.
-- Edit description text between [=[ and ]=]; apostrophes and quotation marks are safe inside.
return {
  version = '0.6.0',
  compatible_versions = {},
  supplements = {},
  features = {
    {
      title = 'Surround',
      card_title = 'Surround',
      overview = [=[Measure surround audio up to 7.1 and see how its speakers combine.]=],
      topics = {
        { id = 'surround_overview', title = 'Overview', renderer = 'surround',
          body = [=[yb-Reference now measures surround audio up to 7.1. Meters, loudness and Spectrum follow every speaker, and the Surround Field shows the whole sound field from above.]=] },
        { id = 'surround_speakers', title = 'Speaker Setup', renderer = 'surround',
          body = [=[When the project master has four, six or eight channels, yb-Reference suggests a speaker layout. Choose Use Recommendation to assign it, or pick another arrangement from Speaker Arrangement. Each project remembers its own layout.]=] },
        { id = 'surround_phase', title = 'Phase', renderer = 'surround',
          body = [=[A side of the Surround Field turns blue when neighbouring speakers are in phase and red when their polarity is opposite. Point at a side to read its correlation.]=] },
      },
    },
    {
      title = 'Reference Panel',
      card_title = 'Reference Panel',
      overview = [=[Keep the reference's picker, readings, waveform and controls together beside the panels.]=],
      topics = {
        { id = 'card_overview', title = 'Overview', renderer = 'card',
          body = [=[The Waveform panel and the bottom bar are now one Reference panel. It sits beside the analysis panels, so one reference's controls stay in one place.]=] },
        { id = 'card_resize', title = 'Resizing', renderer = 'card',
          body = [=[As the window gets shorter, the Reference panel folds its details, then its readings, then its waveform. The picker and playback controls always stay in reach.]=] },
      },
    },
    {
      title = 'Docked Library',
      card_title = 'Docked Library',
      overview = [=[Browse and audition sounds beside Reference View.]=],
      topics = {
        { id = 'library_overview', title = 'Overview', renderer = 'library',
          body = [=[The Library can now stay open beside Reference View, so you can browse and audition sounds while you compare references. Drag its edge to resize it. Its width and visibility are remembered.]=] },
      },
    },
  },
}
