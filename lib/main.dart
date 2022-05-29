import 'dart:async';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'dart:math';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'grid.dart';

void main() {
  runApp(MyApp());
  SystemChrome.setEnabledSystemUIOverlays([]);
}

class MyApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kumquats',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MyHomePage(title: 'Kumquats'),
      // debugShowCheckedModeBanner: false,
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key? key, this.title = ""}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

// https://docs.google.com/document/d/1yohSuYrvyya5V1hB6j9pJskavCdVq9sVeTqSoEPsWH0/edit#
final ButtonStyle raisedButtonStyle = ElevatedButton.styleFrom(
  onPrimary: Colors.black87,
  primary: Colors.grey[300],
  minimumSize: Size(88, 36),
  padding: EdgeInsets.symmetric(horizontal: 16),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(2)),
  ),
);

enum GameMode {
  not_started,
  starting,
  in_progress,
  ended,
}

enum DialogMode {
  none,
  main_menu,
  game_over,
  preferences,
}

enum IllegalWordHighlightMode {
  never,
  all_tiles_played,
  always,
}

final illegalWordHighlightModePrefsKey = "illegal_word_highlight";
final numTilesPrefsKey = "tiles_per_game";
final numBestTimesToStore = 5;

String bestTimesPrefsKey(int numTiles) => "best_times.${numTiles}";

class GameTimeRecord {
  final int elapsedMillis;
  final int timestampMillis;

  GameTimeRecord(this.elapsedMillis, this.timestampMillis);

  Map<String, dynamic> toJson() => {
    "elapsed_millis": this.elapsedMillis,
    "timestamp_millis": this.timestampMillis,
  };

  GameTimeRecord.fromJson(Map<String, dynamic> json):
      elapsedMillis = json["elapsed_millis"],
      timestampMillis = json["timestamp_millis"];
}

class Layout {
  Size size = Size.zero;
  double gridTileSize = 0;
  double rackTileSize = 0;
  double gridLineWidth = 0;
  Size availableGridSize = Size.zero;
  Rect gridRect = Rect.zero;
  Rect rackRect = Rect.zero;
  Rect statusRect = Rect.zero;
  Offset gridDisplayOffset = Offset.zero;
  int numXCells = 0;
  int numYCells = 0;

  double pixelsPerGridCell() {
    return gridTileSize + gridLineWidth;
  }

  double totalGridWidth() {
    return numXCells * (gridTileSize + gridLineWidth) + gridLineWidth;
  }

  double totalGridHeight() {
    return numYCells * (gridTileSize + gridLineWidth) + gridLineWidth;
  }

  bool usesWideRack() {
    return rackRect.width >= size.width;
  }

  Offset offsetForGridXY(int x, int y) {
    final xoff = x * this.pixelsPerGridCell() + this.gridLineWidth - this.gridDisplayOffset.dx;
    final yoff = y * this.pixelsPerGridCell() + this.gridLineWidth - this.gridDisplayOffset.dy;
    return Offset(xoff, yoff);
  }
}

class RackTile {
  String letter;
  double longAxisCenter;
  double shortAxisCenter;

  RackTile(this.letter, this.longAxisCenter, this.shortAxisCenter);
}

class AnimatedRackTile {
  RackTile tile;
  Offset origin;

  AnimatedRackTile(this.tile, this.origin);
}

class AnimatedGridTile {
  Offset origin;
  Coord destination;

  AnimatedGridTile(this.destination, this.origin);
}

class DragTile {
  String letter = "";
  Offset dragStart = Offset.zero;
  Offset currentPosition = Offset.zero;
  double tileSize = 0;
  // Either rackTile or gridCoord coordinates should be set.
  RackTile? rackTile;
  Coord? gridCoord;
}

final letterFrequencies = {
  18: ["E"],
  13: ["A"],
  12: ["I"],
  11: ["O"],
  9: ["T", "R"],
  8: ["N"],
  6: ["D", "S", "U"],
  5: ["L"],
  4: ["G"],
  3: ["B", "C", "F", "H", "M", "P", "V", "W", "Y"],
  2: ["J", "K", "Q", "X", "Z"],
};

final hiriganaFrequencies = {
  2: "あいうえおかきくけこさしすせそたちつてとはひふへほまみむめもやゆよらりるれろわをん".split(''),
};

List<String> shuffleTiles(Map<int, List<String>> frequencies, Random rng) {
  List<String> chars = [];
  for (final entry in frequencies.entries) {
    final count = entry.key;
    for (final ch in entry.value) {
      for (var i = 0; i < count; i++) {
        chars.add(ch);
      }
    }
  }
  chars.shuffle(rng);
  // Use to force starting letters for testing.
  final forcedLetters = "";
  for (var i = 0; i < forcedLetters.length; i++) {
    chars[i] = forcedLetters[i];
  }
  return chars;
}

final tileBackgroundColor = Color.fromARGB(255, 240, 200, 100);
final invalidTileBackgroundColor = Color.fromARGB(255, 240, 60, 30);
final tileTextColor = Color.fromARGB(255, 48, 48, 48);
final tileBorderColor = Color.fromARGB(255, 200, 160, 60);
final boardBackgroundColor = Color.fromARGB(255, 240, 240, 240);
final boardGridLineColor = Colors.black38;
final rackBackgroundColor = Colors.teal[900];
final statusBackgroundColor = Colors.green[300];
final dialogBackgroundColor = Color.fromARGB(0xd0, 0xd8, 0xd8, 0xd8);

class _MyHomePageState extends State<MyHomePage> {
  final rng = Random();
  late SharedPreferences preferences;
  var dragStart = Offset.zero;
  var gridOffsetAtDragStart = Offset.zero;
  var gridOffset = Offset.zero;
  var zoomScale = 1.0;
  var zoomScaleAtGestureStart = 1.0;
  var gameMode = GameMode.not_started;
  var dialogMode = DialogMode.none;
  var illegalWordHighlightMode = IllegalWordHighlightMode.always;

  LetterGrid grid = LetterGrid(1, 1);
  GridRules rules = GridRules(qHandling: QTileHandling.qOrQu);
  List<RackTile> rackTiles = [];
  List<AnimatedRackTile> animatedRackTiles = [];
  List<AnimatedGridTile> animatedGridTiles = [];
  DragTile? dragTile;

  List<String> letterBag = [];
  int bagIndex = 0;
  int lettersInGame = 72;
  var gameStopwatch = Stopwatch();

  final initialNewTileDelay = Duration(seconds: 60);
  final inGameNewTileDelay = Duration(seconds: 10);
  int scheduledDrawTileId = 0;

  Set<String> dictionary = {};
  Set<Coord> invalidLetterCoords = {};

  @override void initState() {
    super.initState();
    _loadDictionary();
    _readPreferencesAndStartGame();
  }

  Future<void> _loadDictionary() async {
    print("Loading words");
    final timer = Stopwatch();
    timer.start();
    this.dictionary.clear();
    final files = ["TWL06.txt", "2letter.txt", "3letter.txt"];
    for (final f in files) {
      String wordStr = await DefaultAssetBundle.of(this.context).loadString("assets/words/${f}");
      this.dictionary.addAll(wordStr.split("\n"));
    }
    timer.stop();
    print("Read ${this.dictionary.length} words in ${timer.elapsedMilliseconds} ms");
  }

  Future<void> _readPreferencesAndStartGame() async {
    this.preferences = await SharedPreferences.getInstance();
    final highlightStr = this.preferences.getString(illegalWordHighlightModePrefsKey) ?? '';
    this.illegalWordHighlightMode = IllegalWordHighlightMode.values.firstWhere(
            (s) => s.toString() == highlightStr, orElse: () => IllegalWordHighlightMode.always);
    this.startGame(letterFrequencies);
  }

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (this.gameMode == GameMode.in_progress && this.dragTile == null) {
        this.setState(() {});
      }
    });
  }

  void addInitialTileAfterDelay() {
    Future.delayed(const Duration(milliseconds: 50), () {
      final x = this.bagIndex % 7;
      final y = this.bagIndex ~/ 7;
      this.setState(() {
        this.rackTiles.add(RackTile(this.letterBag[this.bagIndex], 0.08 + 0.14 * x, 0.2 + 0.3 * y));
        this.bagIndex += 1;
        if (this.bagIndex >= 21) {
          this.gameMode = GameMode.in_progress;
          this.gameStopwatch.reset();
          this.gameStopwatch.start();
        }
        else {
          addInitialTileAfterDelay();
        }
      });
    });
  }

  void startGame(Map<int, List<String>> frequencies) {
    this.gameMode = GameMode.starting;
    this.lettersInGame = readNumTilesPerGameFromPrefs();
    this.grid = LetterGrid(15, 15);
    this.gridOffset = Offset.zero;
    this.zoomScale = 1.0;
    this.letterBag = shuffleTiles(frequencies, this.rng);
    this.bagIndex = 0;
    this.rackTiles = [];
    this.gameStopwatch.stop();
    this.gameStopwatch.reset();
    this.addInitialTileAfterDelay();
    this.scheduleDrawTile(initialNewTileDelay);
  }

  void updateZoomScale(Offset localZoomPoint, double newScale) {
    final displaySize = MediaQuery.of(context).size;
    final layout = layoutForDisplaySize(displaySize);

    final xFrac = localZoomPoint.dx / layout.gridRect.width;
    final yFrac = localZoomPoint.dy / layout.gridRect.height;
    final xZoomCell = (layout.gridDisplayOffset.dx + localZoomPoint.dx) / layout.pixelsPerGridCell();
    final yZoomCell = (layout.gridDisplayOffset.dy + localZoomPoint.dy) / layout.pixelsPerGridCell();

    this.zoomScale = newScale.clamp(0.25, 3.0);
    final newLayout = layoutForDisplaySize(displaySize);

    final widthInCells = newLayout.gridRect.width / newLayout.pixelsPerGridCell();
    final xStartCell = xZoomCell - xFrac * widthInCells;
    final heightInCells = newLayout.gridRect.height / newLayout.pixelsPerGridCell();
    final yStartCell = yZoomCell - yFrac * heightInCells;

    final xoff = xStartCell * newLayout.pixelsPerGridCell();
    final yoff = yStartCell * newLayout.pixelsPerGridCell();
    if (newLayout.totalGridWidth() < newLayout.availableGridSize.width &&
        newLayout.totalGridHeight() < newLayout.availableGridSize.height) {
      final scaleUpRatio = min(
          newLayout.availableGridSize.width / newLayout.totalGridWidth(),
          newLayout.availableGridSize.height / newLayout.totalGridHeight());
      this.zoomScale *= scaleUpRatio;
      this.gridOffset = Offset.zero;
    }
    else {
      this.gridOffset = Offset(xoff, yoff);
    }
  }

  void handlePointerEvent(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (event.scrollDelta.dy > 0) {
        setState(() {updateZoomScale(event.localPosition, zoomScale * 0.95);});
      }
      else if (event.scrollDelta.dy < 0) {
        setState(() {updateZoomScale(event.localPosition, zoomScale * 1.05);});
      }
    }
  }

  Layout layoutForDisplaySize(Size displaySize) {
    final layout = Layout();
    final baseDim = displaySize.height;
    layout.size = displaySize;
    layout.gridTileSize = baseDim * 0.06 * this.zoomScale;
    layout.gridLineWidth = baseDim * 0.0025 * this.zoomScale;
    layout.numXCells = grid.numXCells();
    layout.numYCells = grid.numYCells();

    final maxGridWidth = layout.numXCells * layout.pixelsPerGridCell() + layout.gridLineWidth;
    final maxGridHeight = layout.numYCells * layout.pixelsPerGridCell() + layout.gridLineWidth;
    final statusHeight = 0.06 * displaySize.longestSide;
    if (displaySize.height >= displaySize.width) {
      layout.availableGridSize = Size(displaySize.width, displaySize.height * 0.67);
      layout.gridRect = Rect.fromLTRB(
          0, 0,
          min(layout.availableGridSize.width, maxGridWidth),
          min(layout.availableGridSize.height, maxGridHeight));
      layout.rackRect = Rect.fromLTRB(0, layout.availableGridSize.height, displaySize.width, displaySize.height - statusHeight);
      layout.statusRect = Rect.fromLTRB(0, layout.rackRect.bottom, displaySize.width, displaySize.height);
    }
    else {
      layout.rackRect = Rect.fromLTRB(0, 0, 0.25 * displaySize.width, displaySize.height - statusHeight);
      layout.availableGridSize = Size(displaySize.width - layout.rackRect.width, displaySize.height - statusHeight);
      layout.gridRect = Rect.fromLTWH(
          layout.rackRect.right, 0,
          min(layout.availableGridSize.width, maxGridWidth),
          min(layout.availableGridSize.height, maxGridHeight));
      layout.statusRect = Rect.fromLTRB(0, displaySize.height - statusHeight, displaySize.width, displaySize.height);
    }
    layout.rackTileSize = min(0.12 * layout.rackRect.longestSide, 0.2 * layout.rackRect.shortestSide);

    final maxDx = layout.numXCells * layout.pixelsPerGridCell() + layout.gridLineWidth - layout.gridRect.width;
    double dx = (maxDx > 0) ? 1.0 * gridOffset.dx.clamp(0, maxDx) : 0;
    final maxDy = layout.numYCells * layout.pixelsPerGridCell() + layout.gridLineWidth - layout.gridRect.height;
    double dy = (maxDy > 0) ? 1.0 * gridOffset.dy.clamp(0, maxDy) : 0;
    layout.gridDisplayOffset = Offset(dx, dy);

    return layout;
  }

  void handleMouseHover(PointerHoverEvent event) {
    // print('Hover ${event.position.dx} ${event.position.dy}');
  }

  void handlePanStart(ScaleStartDetails event) {
    dragStart = event.localFocalPoint;
    gridOffsetAtDragStart = Offset(gridOffset.dx, gridOffset.dy);
    zoomScaleAtGestureStart = zoomScale;
  }

  void handlePanUpdate(ScaleUpdateDetails event) {
    var diff = dragStart - event.localFocalPoint;
    setState(() {
      // Zoom or pan, but not both.
      if (event.scale == 1.0) {
        gridOffset = gridOffsetAtDragStart + diff;
      }
      else {
        updateZoomScale(event.localFocalPoint, zoomScaleAtGestureStart * event.scale);
      }
    });
  }

  void handlePanEnd(ScaleEndDetails event) {
    // print("drag end: ${event.velocity}");
  }

  void gridTileDragStart(DragStartDetails event, int gridX, int gridY) {
    if (gameMode != GameMode.in_progress) {
      return;
    }
    final dt = DragTile();
    dt.letter = this.grid.atXY(gridX, gridY);
    dt.dragStart = event.globalPosition;
    dt.currentPosition = event.globalPosition;
    dt.gridCoord = Coord(gridX, gridY);
    setState(() {this.dragTile = dt;});
  }

  void gridTileDragUpdate(DragUpdateDetails event) {
    if (gameMode != GameMode.in_progress) {
      return;
    }
    setState(() {this.dragTile!.currentPosition = event.globalPosition;});
  }

  void gridTileDragEnd(DragEndDetails event) {
    if (gameMode != GameMode.in_progress) {
      return;
    }
    handleDragEnd(event);
  }

  void rackTileDragStart(DragStartDetails event, RackTile rt) {
    if (gameMode != GameMode.in_progress) {
      return;
    }
    final dt = DragTile();
    dt.letter = rt.letter;
    dt.dragStart = event.globalPosition;
    dt.currentPosition = event.globalPosition;
    dt.rackTile = rt;
    setState(() {this.dragTile = dt;});
  }

  void rackTileDragUpdate(DragUpdateDetails event) {
    if (gameMode != GameMode.in_progress) {
      return;
    }
    setState(() {this.dragTile!.currentPosition = event.globalPosition;});
  }

  void rackTileDragEnd(DragEndDetails event) {
    if (gameMode != GameMode.in_progress) {
      return;
    }
    handleDragEnd(event);
  }

  Set<Coord> computeInvalidLetterCoords() {
    return this.grid.coordinatesWithInvalidWords(this.dictionary, rules);
  }

  void handleDragEnd(DragEndDetails event) {
    final displaySize = MediaQuery.of(context).size;
    final layout = layoutForDisplaySize(displaySize);
    final dt = this.dragTile!;
    final dropPosition = dt.currentPosition;
    if (layout.rackRect.contains(dropPosition)) {
      final xFraction = (dropPosition.dx - layout.rackRect.left) / layout.rackRect.width;
      final yFraction = (dropPosition.dy - layout.rackRect.top) / layout.rackRect.height;
      final longAxisFraction = layout.usesWideRack() ? xFraction : yFraction;
      final shortAxisFraction = layout.usesWideRack() ? yFraction : xFraction;
      if (dt.rackTile != null) {
        // Dragging from rack, move to end of array so it will be on top.
        setState(() {
          dt.rackTile!.longAxisCenter = longAxisFraction;
          dt.rackTile!.shortAxisCenter = shortAxisFraction;
          this.rackTiles.remove(dt.rackTile);
          this.rackTiles.add(dt.rackTile!);
        });
      }
      else {
        // Dragging from grid, clear grid cell and create new rack tile.
        setState(() {
          this.grid.setAtXY(dt.gridCoord!.x, dt.gridCoord!.y, "");
          this.rackTiles.add(RackTile(dt.letter, longAxisFraction, shortAxisFraction));
        });
      }
    }
    else if (layout.gridRect.contains(dropPosition)) {
      // Determine cell of dropPosition.
      int dropGridX = (dropPosition.dx + layout.gridDisplayOffset.dx - layout.gridRect.left) ~/ layout.pixelsPerGridCell();
      int dropGridY = (dropPosition.dy + layout.gridDisplayOffset.dy - layout.gridRect.top) ~/ layout.pixelsPerGridCell();
      if (dropGridX >= 0 && dropGridX < layout.numXCells &&
          dropGridY >= 0 && dropGridY < layout.numYCells &&
          this.grid.isEmptyAtXY(dropGridX, dropGridY)) {
        setState(() {
          this.grid.setAtXY(dropGridX, dropGridY, dt.letter);
          if (dt.rackTile != null) {
            this.rackTiles.remove(dt.rackTile);
          }
          else {
            this.grid.setAtXY(dt.gridCoord!.x, dt.gridCoord!.y, "");
          }
          this.expandGridIfNeeded(dropGridX, dropGridY);
          this.checkForGameOver();
          this.checkForDrawTile();
        });
      }
      else {
        // Animate back to original position.
        if (dt.rackTile != null) {
          Offset animOffset = Offset(layout.rackTileSize / 2, layout.rackTileSize / 2);
          this.animatedRackTiles.add(AnimatedRackTile(dt.rackTile!, dropPosition - animOffset));
        }
        else {
          Offset animOffset = Offset(layout.gridTileSize / 2, layout.gridTileSize / 2);
          this.animatedGridTiles.add(AnimatedGridTile(dt.gridCoord!, dropPosition - animOffset));
        }
      }
    }
    setState(() {
      this.dragTile = null;
      this.invalidLetterCoords = computeInvalidLetterCoords();
    });
  }

  void scheduleDrawTile(Duration delay) {
    this.scheduledDrawTileId += 1;
    final expectedTileId = this.scheduledDrawTileId;
    Future.delayed(delay, () {
      if (expectedTileId == this.scheduledDrawTileId && this.bagIndex < this.lettersInGame) {
        if (this.rackTiles.length < 21) {
          drawTileFromBag();
        }
        this.scheduleDrawTile(inGameNewTileDelay);
      }
    });
  }

  void drawTileFromBag() {
    Size displaySize = this.context.size!;
    final layout = layoutForDisplaySize(displaySize);
    final startPos = layout.usesWideRack() ?
        Offset(displaySize.width / 2, displaySize.height) : Offset(0, displaySize.height / 2);
    final x = 0.15 + 0.7 * this.rng.nextDouble();
    final y = 0.15 + 0.7 * this.rng.nextDouble();
    RackTile rt = RackTile(this.letterBag[this.bagIndex], x, y);
    this.bagIndex += 1;
    this.animatedRackTiles.add(AnimatedRackTile(rt, startPos));
  }

  void expandGridIfNeeded(int gridX, int gridY) {
    final minPadding = 2;
    if (gridX < minPadding) {
      this.grid.extendEdge(GridEdge.Left, minPadding - gridX);
    }
    if (gridX >= this.grid.numXCells() - minPadding) {
      this.grid.extendEdge(GridEdge.Right, gridX + minPadding + 1 - this.grid.numXCells());
    }
    if (gridY < minPadding) {
      this.grid.extendEdge(GridEdge.Top, minPadding - gridY);
    }
    if (gridY >= this.grid.numYCells() - minPadding) {
      this.grid.extendEdge(GridEdge.Bottom, gridY + minPadding + 1 - this.grid.numYCells());
    }
  }

  bool allTilesPlaced() {
    return
        this.bagIndex >= this.lettersInGame &&
        this.rackTiles.isEmpty &&
        this.grid.connectedLetterGroups().length == 1;
  }

  void checkForDrawTile() {
    if (this.gameMode == GameMode.in_progress &&
        this.rackTiles.isEmpty &&
        this.bagIndex < this.lettersInGame &&
        this.grid.connectedLetterGroups().length == 1 &&
        this.computeInvalidLetterCoords().isEmpty) {
      drawTileFromBag();
      this.scheduleDrawTile(inGameNewTileDelay);
    }
  }

  void checkForGameOver() async {
    if (allTilesPlaced() && computeInvalidLetterCoords().isEmpty) {
      this.gameStopwatch.stop();
      await this.updateBestTimes(this.gameStopwatch.elapsedMilliseconds);
      setState(() {
        this.gameMode = GameMode.ended;
        this.dialogMode = DialogMode.game_over;
        this.scheduledDrawTileId += 1;
      });
    }
  }

  int readNumTilesPerGameFromPrefs() {
    try {
      final n = this.preferences.getInt(numTilesPrefsKey);
      return n ?? 36;
    } catch (ex) {
      return 36;
    }
  }

  List<GameTimeRecord> readBestTimesFromPrefs(String prefsKey) {
    try {
      final stored = this.preferences.getString(prefsKey);
      final decoded = jsonDecode(stored ?? "[]") as List<dynamic>;
      return decoded.map((j) => GameTimeRecord.fromJson(j)).toList(growable: true);
    } catch (ex) {
      return [];
    }
  }

  Future<List<GameTimeRecord>> updateBestTimes(int millis) async {
    final prefsKey = bestTimesPrefsKey(this.lettersInGame);
    List<GameTimeRecord> newBestTimes = readBestTimesFromPrefs(prefsKey);
    print("Read best times: ${jsonEncode(newBestTimes)}");
    try {
      final record = GameTimeRecord(millis, DateTime.now().millisecondsSinceEpoch);
      final index = newBestTimes.indexWhere((t) => millis < t.elapsedMillis);
      if (index == -1 && newBestTimes.length < numBestTimesToStore) {
        newBestTimes.add(record);
        await this.preferences.setString(prefsKey, jsonEncode(newBestTimes));
      }
      else if (index < numBestTimesToStore) {
        newBestTimes.insert(index, record);
        while (newBestTimes.length > numBestTimesToStore) {
          newBestTimes.removeLast();
        }
        await this.preferences.setString(prefsKey, jsonEncode(newBestTimes));
      }
    } catch (ex) {
      print("Error saving times: ${ex}");
    }
    return newBestTimes;
  }

  Widget letterTile(String letter, double cellSize, {invalid = false}) {
    final background = invalid ? invalidTileBackgroundColor : tileBackgroundColor;
    return Container(width: cellSize, height: cellSize,
        decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(cellSize * 0.15),
            border: Border.all(
                color: tileBorderColor,
                width: cellSize * 0.02,
            ),
        ),
        child: Text(letter, textAlign: TextAlign.center, style: TextStyle(color: tileTextColor, fontSize: cellSize * 0.8)));
  }

  List<Widget> gridLines(final Layout layout) {
    final List<Widget> lines = [];

    for (var i = 0; i <= layout.numXCells; i++) {
      final x = i * layout.pixelsPerGridCell() - layout.gridDisplayOffset.dx;
      lines.add(Transform.translate(
          offset: Offset(x, 0),
          child: VerticalDivider(
              width: 0, thickness: layout.gridLineWidth, color: boardGridLineColor)));
    }
    for (var i = 0; i <= layout.numYCells; i++) {
      final y = i * layout.pixelsPerGridCell() - layout.gridDisplayOffset.dy + layout.gridLineWidth;
      lines.add(
          Transform.translate(
              offset: Offset(0, y),
              child: Divider(
                  height: 0, thickness: layout.gridLineWidth, color: boardGridLineColor)));
    }
    return lines;
  }

  bool shouldHighlightIllegalWords() {
    switch (illegalWordHighlightMode) {
      case IllegalWordHighlightMode.always:
        return true;
      case IllegalWordHighlightMode.never:
        return false;
      case IllegalWordHighlightMode.all_tiles_played:
        return allTilesPlaced();
    }
  }

  List<Widget> gridTiles(final Layout layout) {
    final List<Widget> tiles = [];
    final showIllegal = shouldHighlightIllegalWords();
    for (var y = 0; y < grid.numYCells(); y++) {
      for (var x = 0; x < grid.numXCells(); x++) {
        if (!grid.isEmptyAtXY(x, y)) {
          bool isTranslucent =
              (this.dragTile != null && Coord.isAtXY(this.dragTile!.gridCoord, x, y)) ||
                  !this.animatedGridTiles.every((a) => !Coord.isAtXY(a.destination, x, y));
          double opacity = isTranslucent ? 0.2 : 1.0;
          final pos = layout.offsetForGridXY(x, y);
          final invalid = showIllegal && this.invalidLetterCoords.contains(Coord(x, y));
          tiles.add(Transform.translate(offset: pos, child: Opacity(opacity: opacity, child: GestureDetector(
              onPanStart: (event) => gridTileDragStart(event, x, y),
              onPanUpdate: gridTileDragUpdate,
              onPanEnd: gridTileDragEnd,
              child: letterTile(grid.atXY(x, y), layout.gridTileSize, invalid: invalid)))));
        }
      }
    }
    return tiles;
  }

  Widget wordGrid(final Layout layout) {
    return Positioned(
      left: layout.gridRect.left,
      top: layout.gridRect.top,
      width: layout.gridRect.width,
      height: layout.gridRect.height,
      child: Listener(
        onPointerSignal: handlePointerEvent, child: GestureDetector(
        onScaleStart: handlePanStart,
        onScaleUpdate: handlePanUpdate,
        onScaleEnd: handlePanEnd,
        child: ClipRect(child: Container(
          color: boardBackgroundColor,
          child: Stack(children: [
            ...gridLines(layout),
            ...gridTiles(layout),
          ])
      )),
    )));
  }

  Offset rackTilePosition(final RackTile rt, final Layout layout) {
    final x = layout.rackRect.width * (layout.usesWideRack() ? rt.longAxisCenter : rt.shortAxisCenter) - layout.rackTileSize / 2;
    final y = layout.rackRect.height * (layout.usesWideRack() ? rt.shortAxisCenter : rt.longAxisCenter) - layout.rackTileSize  /2;
    return Offset(x, y);
  }

  Widget rackTileWidget(final RackTile rt, final Layout layout) {
    bool isTranslucent = (this.dragTile != null && this.dragTile!.rackTile == rt) ||
        !this.animatedRackTiles.every((a) => a.tile != rt);
    double opacity = isTranslucent ? 0.2 : 1.0;
    final pos = rackTilePosition(rt, layout);
    return Positioned(
        left: pos.dx,
        top: pos.dy,
        child: Opacity(opacity: opacity, child: GestureDetector(
          onPanStart: (event) => rackTileDragStart(event, rt),
          onPanUpdate: rackTileDragUpdate,
          onPanEnd: rackTileDragEnd,
          child: letterTile(rt.letter, layout.rackTileSize)
        )
    ));
  }

  Widget tileArea(final Layout layout) {
    return Positioned(
      left: layout.rackRect.left,
      top: layout.rackRect.top,
      width: layout.rackRect.width,
      height: layout.rackRect.height,
      child: Container(
        color: rackBackgroundColor,
        child: Stack(children: [
          ...rackTiles.map((rt) => rackTileWidget(rt, layout)),
        ]),
      )
    );
  }

  Widget animatedRackTileWidget(final AnimatedRackTile animTile, final Layout layout) {
    final animationDone = () {
      this.animatedRackTiles.remove(animTile);
      this.rackTiles.remove(animTile.tile);
      this.rackTiles.add(animTile.tile);
    };

    final endOffset = layout.rackRect.topLeft + rackTilePosition(animTile.tile, layout);
    return TweenAnimationBuilder(
      tween: Tween(begin: animTile.origin, end: endOffset),
      curve: Curves.ease,
      duration: Duration(milliseconds: 300),
      onEnd: animationDone,
      child: letterTile(animTile.tile.letter, layout.rackTileSize),
      builder: (BuildContext context, Offset position, Widget? child) {
        return Positioned(
          left: position.dx,
          top: position.dy,
          child: child!,
        );
      },
    );
  }

  Widget animatedGridTileWidget(final AnimatedGridTile animTile, final Layout layout) {
    final animationDone = () {
      this.animatedGridTiles.remove(animTile);
    };

    final dest = animTile.destination;
    final endOffset = layout.offsetForGridXY(dest.x, dest.y) + layout.gridRect.topLeft;
    return TweenAnimationBuilder(
      tween: Tween(begin: animTile.origin, end: endOffset),
      curve: Curves.ease,
      duration: Duration(milliseconds: 300),
      onEnd: animationDone,
      child: letterTile(grid.atXY(dest.x, dest.y), layout.gridTileSize),
      builder: (BuildContext context, Offset position, Widget? child) {
        return Positioned(
          left: position.dx,
          top: position.dy,
          child: child!,
        );
      },
    );
  }

  String formattedMinutesSecondsFromMillis(int millis) {
    final totalSeconds = (millis / 1000.0).round();
    final minutes = (totalSeconds / 60).truncate();
    final seconds = totalSeconds % 60;
    final secString = ((seconds < 10) ? "0" : "") + seconds.toString();
    return "${minutes}:${secString}";
  }

  String formattedElapsedTime() =>
      formattedMinutesSecondsFromMillis(this.gameStopwatch.elapsedMilliseconds);

  Widget statusArea(final Layout layout) {
    final fontSize = layout.statusRect.height / 2;
    return Positioned(
        left: layout.statusRect.left,
        top: layout.statusRect.top,
        width: layout.statusRect.width,
        height: layout.statusRect.height,
        child: Container(
          color: statusBackgroundColor,
          child: Row(children: [
            Container(width: layout.statusRect.width / 20),
            Text("${this.grid.numberOfFilledCells()} / ${this.lettersInGame}", style: TextStyle(fontSize: fontSize)),
            Expanded(child: Container()),
            Text(formattedElapsedTime(), style: TextStyle(fontSize: fontSize)),
            Expanded(child: Container()),
            ElevatedButton(onPressed: _showMenu, child: Text("Menu")),
            Container(width: layout.statusRect.width / 20),
          ]),
        )
      );
  }

  Widget dragTileWidget(final Layout layout) {
    final tileSize = this.dragTile!.rackTile != null ? layout.rackTileSize : layout.gridTileSize;
    return Positioned(
        left: this.dragTile!.currentPosition.dx - tileSize / 2,
        top: this.dragTile!.currentPosition.dy - tileSize / 2,
        child: letterTile(this.dragTile!.letter, tileSize));
  }

  Widget _paddingAll(final double paddingPx, final Widget child) {
    return Padding(padding: EdgeInsets.all(paddingPx), child: child);
  }

  TableRow makeButtonRow(String title, void Function() onPressed) {
    return TableRow(children: [
      Padding(
        padding: EdgeInsets.all(8),
        child: ElevatedButton(
          style: raisedButtonStyle,
          onPressed: onPressed,
          child: Text(title),
        ),
      ),
    ]);
  }

  Widget _mainMenuDialog(final BuildContext context, final Size displaySize) {
    final minDim = displaySize.shortestSide;

    return Container(
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Dialog(
          backgroundColor: dialogBackgroundColor,
          child: _paddingAll(10, Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _paddingAll(5, Text(
                  'Kumquats!',
                  style: TextStyle(
                    fontSize: minDim / 18,
                  )
              )),
              Table(
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                defaultColumnWidth: const IntrinsicColumnWidth(),
                children: [
                  if (this.gameMode == GameMode.in_progress) makeButtonRow('Continue', _continueGame),
                  makeButtonRow('New Game', _startEnglish),
                  // makeButtonRow('新しいゲーム', _startJapanese),
                  makeButtonRow('Preferences...', _showPreferences),
                  makeButtonRow('About...', () => _showAboutDialog(context)),
                ],
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _gameOverDialog(final BuildContext context, final Size displaySize) {
    final minDim = displaySize.shortestSide;
    final maxDim = displaySize.longestSide;
    final titleFontSize = min(maxDim / 30, minDim / 15);
    final bestTimes = readBestTimesFromPrefs(bestTimesPrefsKey(this.lettersInGame));
    final padding = (minDim * 0.05).clamp(5.0, 10.0);

    final bestTimeTableRow = (GameTimeRecord record) {
      final elapsedTimeStr = formattedMinutesSecondsFromMillis(record.elapsedMillis);
      final gameTime = DateTime.fromMillisecondsSinceEpoch(record.timestampMillis);
      final gameDateStr = DateFormat.yMMMd().format(gameTime);
      final isFromLastGame = this.gameStopwatch.elapsedMilliseconds == record.elapsedMillis;
      final textStyle = TextStyle(
        fontSize: titleFontSize * 0.75,
        fontWeight: isFromLastGame ? FontWeight.bold : FontWeight.normal,
      );
      return TableRow(children: [
        _paddingAll(5, Text(elapsedTimeStr, style: textStyle)),
        _paddingAll(5, Container(width: minDim * 0.02)),
        _paddingAll(5, Text(gameDateStr, style: textStyle)),
      ]);
    };

    return Container(
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Dialog(
          backgroundColor: dialogBackgroundColor,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _paddingAll(padding, Text(
                  'Finished in ${formattedElapsedTime()}!',
                  style: TextStyle(
                    fontSize: titleFontSize,
                  )
              )),

              if (bestTimes.isNotEmpty) ...[
                _paddingAll(10, Text(
                    "Best Times (${this.lettersInGame} tiles)",
                    style: TextStyle(
                      fontSize: titleFontSize * 0.85,
                    )
                )),
                Table(
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  children: bestTimes.map(bestTimeTableRow).toList(),
                )
              ],

              _paddingAll(padding, Table(
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                defaultColumnWidth: const IntrinsicColumnWidth(),
                children: [
                  makeButtonRow('New Game', _startEnglish),
                  // makeButtonRow('新しいゲーム', _startJapanese),
                  makeButtonRow('Preferences...', _showPreferences),
                ],
              )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preferencesDialog(final BuildContext context, final Size displaySize) {
    final minDim = displaySize.shortestSide;
    final maxDim = displaySize.longestSide;
    final titleFontSize = min(maxDim / 32.0, minDim / 18.0);
    final baseFontSize = min(maxDim / 36.0, minDim / 20.0);
    final numTilesInGame = readNumTilesPerGameFromPrefs();

    final makeGameLengthRow = () {
      final menuItemStyle = TextStyle(
          fontSize: baseFontSize * 0.9,
          fontWeight: FontWeight.normal,
          color: Colors.blue,
      );
      return _paddingAll(0, Row(children:[
        Text('Game length:', style: TextStyle(fontSize: baseFontSize)),
        Container(width: baseFontSize * 0.75),
        DropdownButton(
          value: numTilesInGame,
          onChanged: (int? value) async {
            this.preferences.setInt(numTilesPrefsKey, value!);
            setState(() {});
          },
          items: [
            DropdownMenuItem(value: 36, child: Text('Short (36 tiles)', style: menuItemStyle)),
            DropdownMenuItem(
                value: 54, child: Text('Medium (54 tiles)', style: menuItemStyle)),
            DropdownMenuItem(value: 72, child: Text('Long (72 tiles)', style: menuItemStyle)),
          ],
        )]
      ));
    };

    final makeIllegalHighlightOptionRow = (String label, IllegalWordHighlightMode highlightMode) {
      return TableRow(children: [
        RadioListTile(
          dense: true,
          title: Text(label, style: TextStyle(fontSize: baseFontSize * 0.9)),
          groupValue: illegalWordHighlightMode,
          value: highlightMode,
          onChanged: (IllegalWordHighlightMode? mode) async {
            setState(() {illegalWordHighlightMode = mode!;});
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString(illegalWordHighlightModePrefsKey, mode.toString());
          },
        ),
      ]);
    };

    return Container(
        width: double.infinity,
        height: double.infinity,
        child: Center(
          child: Dialog(
            backgroundColor: dialogBackgroundColor,
            // insetPadding: EdgeInsets.all(0),
            child: Padding(padding: EdgeInsets.all(minDim * 0.03),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Preferences', style: TextStyle(fontSize: titleFontSize)),

                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Table(
                        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                        defaultColumnWidth: const IntrinsicColumnWidth(),
                        children: [
                          TableRow(children: [Text("")]),
                          TableRow(children: [makeGameLengthRow()]),
                          TableRow(children: [Text("")]),
                          TableRow(children: [Text('Highlight invalid words:', style: TextStyle(fontSize: baseFontSize))]),
                          makeIllegalHighlightOptionRow("Always", IllegalWordHighlightMode.always),
                          makeIllegalHighlightOptionRow('When all tiles are placed', IllegalWordHighlightMode.all_tiles_played),
                          makeIllegalHighlightOptionRow('Never', IllegalWordHighlightMode.never),
                          TableRow(children: [Text("")]),
                        ],
                      ),
                      ElevatedButton(
                        style: raisedButtonStyle,
                        onPressed: _closePreferences,
                        child: Text('OK'),
                      )
                    ],
                  ),
                ],
              ),
            ),
          ),
        ));
  }

  void _showMenu() {
    setState(() {
      dialogMode = DialogMode.main_menu;
    });
  }

  void _startEnglish() {
    setState(() {
      dialogMode = DialogMode.none;
      startGame(letterFrequencies);
    });
  }

  void _startJapanese() {
    setState(() {
      dialogMode = DialogMode.none;
      startGame(hiriganaFrequencies);
    });
  }

  void _continueGame() {
    setState(() {
      dialogMode = DialogMode.none;
    });
  }

  void _showPreferences() {
    setState(() {
      dialogMode = DialogMode.preferences;
    });
  }

  void _closePreferences() {
    setState(() {
      dialogMode = gameMode == GameMode.ended ? DialogMode.game_over : DialogMode.none;
    });
  }

  void _showAboutDialog(BuildContext context) async {
    final aboutText = await DefaultAssetBundle.of(context).loadString('assets/doc/about.md');
    showAboutDialog(
      context: context,
      applicationName: 'Kumquats',
      applicationVersion: '1.0.0',
      applicationLegalese: '© 2021 Brian Nenninger',
      children: [
        Container(height: 15),
        MarkdownBody(
          data: aboutText,
          onTapLink: (text, href, title) => launch(href!),
          // https://github.com/flutter/flutter_markdown/issues/311
          listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final displaySize = MediaQuery.of(context).size;
    final layout = layoutForDisplaySize(displaySize);
    return Scaffold(
      body: Stack(
          children: <Widget>[
            Container(),
            wordGrid(layout),
            tileArea(layout),
            statusArea(layout),
            ...this.animatedRackTiles.map((a) => animatedRackTileWidget(a, layout)),
            ...this.animatedGridTiles.map((a) => animatedGridTileWidget(a, layout)),
            if (this.dragTile != null) dragTileWidget(layout),
            if (this.dialogMode == DialogMode.main_menu) _mainMenuDialog(context, displaySize),
            if (this.dialogMode == DialogMode.game_over) _gameOverDialog(context, displaySize),
            if (this.dialogMode == DialogMode.preferences) _preferencesDialog(context, displaySize),
          ],
        ),
    );
  }
}
