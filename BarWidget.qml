import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui

// Spotify now-playing. The bar shows the Spotify mark plus "title · artist";
// the panel is a small media player: cover art, title, artist, album, a seek
// bar and previous / play-pause / next.
//
// Talks to Spotify over MPRIS directly (Quickshell.Services.Mpris) rather than
// through omarchy.media, because that service follows whichever player is
// loudest and this widget should only ever drive Spotify.
Panel {
  id: root
  moduleName: "io.github.steveb98.spotify"
  ipcTarget: "io.github.steveb98.spotify"

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color faint: Qt.darker(foreground, 1.8)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color spotifyGreen: "#1DB954"
  readonly property string spotifyGlyph: String.fromCodePoint(0xF04C7)

  readonly property int maxLabelWidth: setting("maxLabelWidth", 220)
  readonly property bool brandColor: setting("brandColor", true)

  // ---------------------------------------------------------------- player

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: {
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue
      var id = String(p.dbusName || "") + " " + String(p.identity || "") + " " + String(p.desktopEntry || "")
      if (id.toLowerCase().indexOf("spotify") !== -1) return p
    }
    return null
  }

  readonly property bool running: player !== null
  readonly property bool playing: running && player.isPlaying
  readonly property string title: running ? (player.trackTitle || "") : ""
  readonly property string artist: running ? (player.trackArtist || "") : ""
  readonly property string album: running ? (player.trackAlbum || "") : ""
  // Any app can publish MPRIS metadata, so only load cover art over https
  // (Spotify's own CDN) or from a local file, never plain http or other schemes.
  readonly property string artUrl: {
    var u = running ? String(player.trackArtUrl || "") : ""
    return /^(https|file):\/\//i.test(u) ? u : ""
  }
  readonly property bool hasTrack: title !== "" || artist !== ""
  readonly property real length: running && player.lengthSupported ? player.length : 0
  readonly property real position: running && player.positionSupported ? player.position : 0


  function playPause() {
    if (!player) return
    if (player.canTogglePlaying) player.togglePlaying()
    else if (player.isPlaying && player.canPause) player.pause()
    else if (player.canPlay) player.play()
  }
  function next() { if (player && player.canGoNext) player.next() }
  function previous() { if (player && player.canGoPrevious) player.previous() }
  function seek(seconds) { if (player && player.canSeek) player.position = seconds }

  // Match the window by class only. omarchy-launch-or-focus also matches
  // titles, so any window titled "...Spotify..." (a browser tab, a terminal)
  // was focused instead and Spotify never launched.
  function openSpotify() {
    if (bar) bar.run(
      "addr=$(hyprctl clients -j | jq -r '.[] | select(.class | test(\"^spotify$\"; \"i\")) | .address' | head -n1); "
      + "if [ -n \"$addr\" ]; then hyprctl dispatch \"hl.dsp.focus({ window = \\\"address:$addr\\\" })\" >/dev/null; "
      + "elif command -v spotify >/dev/null; then exec setsid uwsm-app -- spotify; "
      + "else exec setsid uwsm-app -- spotify-launcher; fi")
    root.close()
  }

  // ---------------------------------------------------------------- connect
  //
  // Spotify Connect devices (phone, speakers, TV, this laptop). MPRIS can't
  // see these, so the spotify-connect helper calls the Web API; it prints one
  // JSON object per call.

  readonly property string helper: String(Qt.resolvedUrl("spotify-connect")).replace(/^file:\/\//, "")
  property var devices: []
  property string devicesError: ""      // "" when fine, else the helper's error code
  property string devicesMessage: ""
  property bool devicesOpen: false
  property bool devicesLoaded: false
  property string transferringId: ""

  readonly property var activeDevice: {
    for (var i = 0; i < devices.length; i++) if (devices[i].active) return devices[i]
    return null
  }

  function deviceGlyph(type) {
    var t = String(type || "").toLowerCase()
    if (t === "computer") return String.fromCodePoint(0xF0379)
    if (t === "smartphone") return String.fromCodePoint(0xF011C)
    if (t === "tablet") return String.fromCodePoint(0xF04F6)
    if (t === "tv") return String.fromCodePoint(0xF0502)
    if (t === "gameconsole") return String.fromCodePoint(0xF02B4)
    if (t === "castvideo" || t === "castaudio") return String.fromCodePoint(0xF0118)
    if (t === "automobile") return String.fromCodePoint(0xF010B)
    if (t === "smartwatch") return String.fromCodePoint(0xF0598)
    return String.fromCodePoint(0xF04C3)  // speaker, AVR, STB, unknown
  }

  function refreshDevices() {
    if (!devicesProc.running) devicesProc.running = true
  }

  function applyDevices(text) {
    var r
    try { r = JSON.parse(text) } catch (e) { r = { ok: false, error: "bad-output", message: "Unexpected helper output" } }
    devicesLoaded = true
    if (r.ok) {
      devices = r.devices || []
      devicesError = ""
      devicesMessage = ""
    } else {
      devicesError = r.error || "error"
      devicesMessage = r.message || "Couldn't load devices"
      if (devicesError === "no-login") devices = []
    }
  }

  function transferTo(device) {
    if (!device || device.active || device.restricted || transferProc.running) return
    transferringId = device.id
    transferProc.command = [root.helper, "transfer", device.id]
    transferProc.running = true
  }

  function applyTransfer(text) {
    var r
    try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Unexpected helper output" } }
    if (!r.ok) {
      devicesError = r.error || "error"
      devicesMessage = r.message || "Couldn't switch device"
    }
    // Spotify takes a moment to report the new active device.
    settleTimer.restart()
  }

  // The guided setup is interactive (browser + pasting a Client ID), so it
  // runs in Omarchy's floating terminal rather than from the panel.
  function shq(v) { return "'" + String(v).replace(/'/g, "'\\''") + "'" }

  function runSetup() {
    // Quoted twice: bar.run's bash, then the launcher's own bash -c.
    if (bar) bar.run("omarchy-launch-floating-terminal-with-presentation " + shq(shq(root.helper) + " setup"))
    root.close()
  }

  function toggleDevices() {
    devicesOpen = !devicesOpen
    if (devicesOpen) refreshDevices()
  }

  onOpenedChanged: {
    if (opened) refreshDevices()
    else devicesOpen = false
  }

  Process {
    id: devicesProc
    command: [root.helper, "devices"]
    stdout: StdioCollector { onStreamFinished: root.applyDevices(text) }
  }

  Process {
    id: transferProc
    stdout: StdioCollector { onStreamFinished: root.applyTransfer(text) }
  }

  Timer {
    id: settleTimer
    interval: 1500
    onTriggered: { root.transferringId = ""; root.refreshDevices() }
  }

  // Devices come and go (a phone locks, a speaker sleeps); keep the open
  // list honest without polling while the panel is closed.
  Timer {
    interval: 10000
    repeat: true
    running: root.opened && root.devicesOpen
    onTriggered: root.refreshDevices()
  }

  function clock(seconds) {
    var s = Math.max(0, Math.floor(seconds || 0))
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    var sec = s % 60
    var pad = function(n) { return n < 10 ? "0" + n : String(n) }
    return h > 0 ? h + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec)
  }

  // MPRIS position is not pushed; it has to be re-read. Only bother while
  // the panel is open and the seek bar is actually on screen.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.playing
    triggeredOnStart: true
    onTriggered: if (root.player) root.player.positionChanged()
  }

  // ---------------------------------------------------------------- bar

  implicitWidth: root.vertical ? root.barSize : barRow.implicitWidth + Style.space(14)
  implicitHeight: root.vertical ? Style.bar.iconSlot : root.barSize

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: barGlyph
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.spotifyGlyph
      color: root.playing && root.brandColor ? root.spotifyGreen
           : root.running ? root.barForeground
           : Qt.darker(root.barForeground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
      Behavior on color { ColorAnimation { duration: 160 } }
    }

    // Width follows the text actually on screen, so the bar eases between
    // a short title and a long artist name instead of jumping.
    Item {
      id: labelClip
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.vertical && root.hasTrack && root.maxLabelWidth > 0
      width: Math.min(Math.ceil(labelMetrics.advanceWidth), root.maxLabelWidth)
      height: barText.implicitHeight
      clip: true
      Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

      TextMetrics {
        id: labelMetrics
        font: barText.font
        text: root.shownLabel
      }

      Text {
        id: barText
        width: parent.width
        textFormat: Text.PlainText
        text: root.shownLabel
        elide: Text.ElideRight
        color: root.playing ? root.barForeground : Qt.darker(root.barForeground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        transform: Translate { id: labelShift; y: 0 }
        Behavior on color { ColorAnimation { duration: 160 } }
      }
    }
  }

  // ---------- Bar label: title, or the artist while hovered ----------
  //
  // Podcasts carry no artist; their show name arrives as the album, so hover
  // falls back to that.
  readonly property string hoverLine: artist || album
  readonly property bool showingHoverLine: hoverSwapped && barMouse.containsMouse && hoverLine !== "" && !opened

  // A short artist under a long title shrinks the widget, and which edge
  // moves depends on the bar section: in "right" the left edge slides in. If
  // the pointer sat on the part that slides away, the label shrank out from
  // under it, un-hovered, grew back under it, and looped. So only swap when
  // the pointer is on the part of the widget that stays put after the
  // shrink, then hold the swap until the pointer really leaves.
  property bool hoverSwapped: false

  readonly property string barSection: {
    var layout = bar && bar.layoutConfig ? bar.layoutConfig : {}
    var regions = ["left", "center", "right"]
    for (var r = 0; r < regions.length; r++) {
      var list = layout[regions[r]] || []
      for (var i = 0; i < list.length; i++)
        if (list[i] && list[i].id === moduleName) return regions[r]
    }
    return "right"
  }

  TextMetrics {
    id: hoverMetrics
    font: barText.font
    text: root.hoverLine
  }

  function pointerInStableZone(x) {
    var labelNow = Math.min(Math.ceil(labelMetrics.advanceWidth), maxLabelWidth)
    var labelNext = Math.min(Math.ceil(hoverMetrics.advanceWidth), maxLabelWidth)
    var shrink = labelNow - labelNext
    if (shrink <= 0) return true               // growing: still under the pointer
    if (barSection === "left") return x <= width - shrink
    if (barSection === "center") return x >= shrink / 2 && x <= width - shrink / 2
    return x >= shrink                         // right: the right edge is fixed
  }

  function updateHoverSwap() {
    if (!barMouse.containsMouse) hoverSwapped = false
    else if (!hoverSwapped && pointerInStableZone(barMouse.mouseX)) hoverSwapped = true
  }
  readonly property string targetLabel: showingHoverLine ? hoverLine : title
  property string shownLabel: ""
  property string shownTitle: ""   // the title behind shownLabel, to tell a track change from a hover swap
  property bool labelSlide: false

  onTargetLabelChanged: {
    if (shownLabel === "" || !labelClip.visible) {
      labelSwap.stop()
      barText.opacity = 1
      labelShift.y = 0
      shownLabel = targetLabel
      shownTitle = title
      return
    }
    labelSlide = title !== shownTitle && shownTitle !== ""
    labelSwap.restart()
  }

  Component.onCompleted: { shownLabel = targetLabel; shownTitle = title }

  // Hover swap: fade out, swap, fade in. Track change: the same, plus the old
  // title drifts up and the new one rises in from below.
  SequentialAnimation {
    id: labelSwap
    ParallelAnimation {
      NumberAnimation { target: barText; property: "opacity"; to: 0; duration: 150; easing.type: Easing.InQuad }
      NumberAnimation { target: labelShift; property: "y"; to: root.labelSlide ? -6 : 0; duration: 150; easing.type: Easing.InQuad }
    }
    ScriptAction {
      script: {
        root.shownLabel = root.targetLabel
        root.shownTitle = root.title
        labelShift.y = root.labelSlide ? 6 : 0
      }
    }
    ParallelAnimation {
      NumberAnimation { target: barText; property: "opacity"; to: 1; duration: 240; easing.type: Easing.OutQuad }
      NumberAnimation { target: labelShift; property: "y"; to: 0; duration: 280; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: barMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.playPause()
      else if (mouse.button === Qt.RightButton) root.openSpotify()
      else root.toggle()
    }
    onWheel: function(wheel) {
      if (wheel.angleDelta.y > 0) root.previous()
      else if (wheel.angleDelta.y < 0) root.next()
    }
    // With a track, hovering swaps the label to the artist instead; a tooltip
    // on top of that would just repeat it.
    onEntered: {
      root.updateHoverSwap()
      if (root.bar && !root.opened && !root.hasTrack)
        root.bar.showTooltip(root, root.running ? "Spotify: nothing playing" : "Spotify isn't running")
    }
    onPositionChanged: root.updateHoverSwap()
    onExited: {
      root.updateHoverSwap()
      if (root.bar) root.bar.hideTooltip(root)
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx < 0) root.previous()
        else if (dx > 0) root.next()
      }
      onActivateRequested: root.playPause()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " " || t === "p" || t === "P") root.playPause()
        else if (t === "o" || t === "O") root.openSpotify()
        else if (t === "d" || t === "D") root.toggleDevices()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        // ---------- Now playing: cover · title / artist / album ----------
        Row {
          id: nowPlaying
          width: parent.width
          spacing: Style.space(14)

          readonly property real artSize: Style.space(104)

          BorderSurface {
            width: nowPlaying.artSize
            height: nowPlaying.artSize
            radius: Style.spacing.labelGap
            color: Style.normalFillFor(root.foreground, Color.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
            clip: true

            Image {
              id: cover
              anchors.fill: parent
              anchors.margins: Style.space(2)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              sourceSize.width: nowPlaying.artSize * 2
              sourceSize.height: nowPlaying.artSize * 2
              source: root.artUrl
              visible: status === Image.Ready
            }

            Text {
              anchors.centerIn: parent
              visible: cover.status !== Image.Ready
              textFormat: Text.PlainText
              text: root.spotifyGlyph
              color: root.running && root.brandColor ? root.spotifyGreen : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }
          }

          Column {
            width: parent.width - nowPlaying.artSize - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.playing ? "NOW PLAYING" : root.running && root.hasTrack ? "PAUSED" : "SPOTIFY"
              color: root.brandColor && root.playing ? root.spotifyGreen : root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.hasTrack ? root.title : root.running ? "Nothing playing" : "Spotify isn't running"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: root.artist
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: root.album
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
              elide: Text.ElideRight
            }
          }
        }

        // ---------- Seek bar ----------
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.running && root.hasTrack && root.length > 0

          PanelSlider {
            id: seekBar
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: Math.max(1, root.length)
            step: 1
            value: root.position
            enabled: root.player && root.player.canSeek
            fillColor: root.brandColor ? root.spotifyGreen : root.foreground
            onReleased: function(v) { root.seek(v) }
          }

          Item {
            width: parent.width
            height: elapsed.implicitHeight

            Text {
              id: elapsed
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: root.clock(seekBar.dragging ? seekBar.liveValue : root.position)
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: root.clock(root.length)
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ---------- Transport ----------
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)
          visible: root.running

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰒮"
            tooltipText: "Previous"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconSize: Style.font.iconLarge
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            enabled: root.player && root.player.canGoPrevious
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.previous()
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.playing ? "󰏤" : "󰐊"
            tooltipText: root.playing ? "Pause" : "Play"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            selected: root.playing
            iconSize: Style.font.displayLarge
            horizontalPadding: Style.spacing.panelGap
            verticalPadding: Style.spacing.controlPaddingY
            enabled: root.player && (root.player.canTogglePlaying || root.player.canPlay || root.player.canPause)
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.playPause()
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰒭"
            tooltipText: "Next"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconSize: Style.font.iconLarge
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            enabled: root.player && root.player.canGoNext
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.next()
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        // ---------- Footer: Connect device · open the app ----------
        Row {
          id: footer
          width: parent.width
          spacing: Style.spacing.md

          Button {
            width: (footer.width - footer.spacing) / 2
            text: root.activeDevice ? root.activeDevice.name
                : root.devicesError === "no-login" ? "Connect devices"
                : "Devices"
            iconText: root.activeDevice ? root.deviceGlyph(root.activeDevice.type) : String.fromCodePoint(0xF04C3)
            tooltipText: root.activeDevice ? "Playing on " + root.activeDevice.name + " (d to switch)" : "Spotify Connect devices (d)"
            selected: root.devicesOpen
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.toggleDevices()
          }

          Button {
            width: (footer.width - footer.spacing) / 2
            text: root.running ? "Show Spotify" : "Open Spotify"
            iconText: root.spotifyGlyph
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openSpotify()
          }
        }

        // ---------- Device list ----------
        Column {
          id: deviceList
          width: parent.width
          spacing: Style.space(4)
          visible: root.devicesOpen

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "PLAY ON"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
            font.bold: true
          }

          Text {
            width: parent.width
            visible: root.devicesError !== "" || (root.devicesLoaded && root.devices.length === 0) || !root.devicesLoaded
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.devicesError === "no-login"
                  ? "Play on your phone, speakers, TV or another computer. Needs Spotify Premium and a one-time setup (about 2 minutes)."
                : root.devicesError !== "" ? root.devicesMessage
                : !root.devicesLoaded ? "Looking for devices..."
                : "No devices found. Open Spotify on a phone, speaker or computer."
            color: root.devicesError !== "" && root.devicesError !== "no-login" && root.bar ? root.bar.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            width: parent.width
            visible: root.devicesError === "no-login"
            text: "Set up Spotify Connect"
            iconText: String.fromCodePoint(0xF04C3)
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.runSetup()
          }

          Repeater {
            model: root.devices

            BorderSurface {
              id: deviceRow
              required property var modelData
              readonly property bool busy: root.transferringId === modelData.id

              width: deviceList.width
              height: deviceInner.implicitHeight + Style.space(12)
              radius: Style.spacing.labelGap
              color: modelData.active || rowMouse.containsMouse
                ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
              borderSpec: modelData.active ? Border.controlSpec("normal", root.foreground, Color.accent) : Border.none()
              opacity: modelData.restricted ? 0.45 : 1.0

              Row {
                id: deviceInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: deviceRow.borderLeft + Style.space(8)
                anchors.rightMargin: deviceRow.borderRight + Style.space(8)
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(20)
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: root.deviceGlyph(deviceRow.modelData.type)
                  color: deviceRow.modelData.active && root.brandColor ? root.spotifyGreen : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(30)
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: deviceRow.modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: deviceRow.modelData.active
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: deviceRow.busy ? "Switching..."
                        : deviceRow.modelData.active ? "Playing here"
                        : deviceRow.modelData.restricted ? "Can't be controlled remotely"
                        : deviceRow.modelData.type
                    color: deviceRow.modelData.active && root.brandColor ? root.spotifyGreen : root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: !deviceRow.modelData.active && !deviceRow.modelData.restricted
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.transferTo(deviceRow.modelData)
              }
            }
          }
        }
      }
    }
  }
}
