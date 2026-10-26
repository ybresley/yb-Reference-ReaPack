-- Retain one demonstration catalogue, with explicit compatibility for patch releases.
-- Edit description text between [=[ and ]=]; apostrophes and quotation marks are safe inside.
return {
  version = '0.5.0',
  compatible_versions = { '0.5.1', '0.5.2' },
  supplements = {
    ['0.5.2'] = { title = 'Metering and layout improvements' },
    ['0.5.1'] = { title = 'Playback stability' },
  },
  features = {
    {
      title = 'Metering',
      card_title = 'Metering',
      overview = [=[Follow loudness and channel levels alongside your reference displays.]=],
      topics = {
        { id = 'meter_overview', title = 'Overview', renderer = 'meter',
          body = [=[The new metering panel shows how loud your audio is as it plays. Use it to compare reference playback with your Reaper project.]=] },
        { id = 'meter_customization', title = 'Customization', renderer = 'meter',
          body = [=[Choose which meters appear and add an Extra Readings column. Open Loudness settings to adjust the loudness display and its target line.]=] },
      },
    },
    {
      title = 'Stereoscope',
      card_title = 'Stereoscope',
      overview = [=[See the stereo image of your audio in Polar Sample or Lissajous view.]=],
      topics = {
        { id = 'stereo_overview', title = 'Overview', renderer = 'stereo',
          body = [=[The new stereoscope shows the relationship between the left and right channels. Compare Lissajous and Polar Sample views as the same audio plays.]=] },
        { id = 'stereo_customization', title = 'Customization', renderer = 'stereo',
          body = [=[Show correlation beside the scope and adjust the brightness of its dots in Stereo Settings.]=] },
      },
    },
    {
      title = 'Panel Layouts',
      card_title = 'Panel Layouts',
      overview = [=[Use all four panels together and arrange them from Settings.]=],
      topics = {
        { id = 'layout_overview', title = 'Overview', renderer = 'layout',
          body = [=[Reference View now has four panels: Waveform, Spectrum, Stereo and Loudness. Follow the stereo image, meters and loudness history alongside your existing displays.]=] },
        { id = 'layout_settings', title = 'Arrange and Resize', renderer = 'layout',
          body = [=[Choose and arrange panels in Settings → Appearance → Reference View. Your arrangement is remembered, and the layout adapts as you resize the window.]=] },
      },
    },
  },
}
