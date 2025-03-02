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

const appTitle = "Kumquats";
const appVersion = "1.2.0";
const appLegalese = "© 2022-2025 Brian Nenninger";

void main() {
  runApp(MyApp());
  // On Android, hide top status bar and use full size so the grid
  // will draw over any cutouts.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
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

enum TileLegality {
  legal,
  invalid_word,
  disconnected_group,
}

final illegalWordHighlightModePrefsKey = "illegal_word_highlight";
final numTilesPrefsKey = "tiles_per_game";
final qHandlingPrefsKey = "q_tiles";
final numBestTimesToStore = 5;
final newTileSlideInAnimationMillis = 300;

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
  Rect origin;

  AnimatedRackTile(this.tile, this.origin);
}

class AnimatedGridTile {
  Rect origin;
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

final tileBackgroundColors = {
  TileLegality.legal: Color.fromARGB(255, 240, 200, 100),
  TileLegality.invalid_word: Color.fromARGB(255, 240, 60, 30),
  TileLegality.disconnected_group: Color.fromARGB(255, 240, 128, 128),
};

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
    final qStr = this.preferences.getString(qHandlingPrefsKey) ?? '';
    this.rules.qHandling = QTileHandling.values.firstWhere(
            (s) => s.toString() == qStr, orElse: () => QTileHandling.qOrQu);
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
    final statusHeight = (0.1 * displaySize.shortestSide).clamp(60, 120);
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

  Coord? _gridCoordForDragTileCurrentPosition(final Layout layout) {
    final dt = dragTile;
    if (dt == null || !layout.gridRect.contains(dt.currentPosition)) {
      return null;
    }
    int dropGridX = (dt.currentPosition.dx + layout.gridDisplayOffset.dx - layout.gridRect.left) ~/ layout.pixelsPerGridCell();
    int dropGridY = (dt.currentPosition.dy + layout.gridDisplayOffset.dy - layout.gridRect.top) ~/ layout.pixelsPerGridCell();
    if (dropGridX >= 0 && dropGridX < layout.numXCells &&
        dropGridY >= 0 && dropGridY < layout.numYCells) {
      return Coord(dropGridX, dropGridY);
    }
    return null;
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
        // TODO: animate
        setState(() {
          this.grid.setAtXY(dt.gridCoord!.x, dt.gridCoord!.y, "");
          this.rackTiles.add(RackTile(dt.letter, longAxisFraction, shortAxisFraction));
        });
      }
    }
    else {
      final dropCoord = _gridCoordForDragTileCurrentPosition(layout);
      if (dropCoord != null && this.grid.isEmptyAtXY(dropCoord.x, dropCoord.y)) {
        setState(() {
          this.grid.setAtXY(dropCoord.x, dropCoord.y, dt.letter);
          if (dt.gridCoord != null) {
            this.grid.setAtXY(dt.gridCoord!.x, dt.gridCoord!.y, "");
          }
          // If we expand the grid to the left or top, we need to adjust the
          // destination cell of the animation.
          final shift = grid.expandIfNeededForPadding(dropCoord.x, dropCoord.y);
          final updatedDropCoord = Coord(dropCoord.x + shift.x, dropCoord.y + shift.y);
          if (dt.rackTile != null) {
            Rect srcRect = Rect.fromCircle(center: dt.currentPosition, radius: layout.rackTileSize / 2);
            this.animatedGridTiles.add(AnimatedGridTile(updatedDropCoord, srcRect));
            this.rackTiles.remove(dt.rackTile);
          }
          else {
            Rect srcRect = Rect.fromCircle(center: dropPosition, radius: layout.gridTileSize / 2);
            this.animatedGridTiles.add(AnimatedGridTile(updatedDropCoord, srcRect));
          }
          this.checkForGameOver();
          this.checkForDrawTile();
        });
      }
      else {
        // Animate back to original position.
        if (dt.rackTile != null) {
          Rect srcRect = Rect.fromCircle(center: dropPosition, radius: layout.rackTileSize / 2);
          this.animatedRackTiles.add(AnimatedRackTile(dt.rackTile!, srcRect));
        }
        else {
          Rect srcRect = Rect.fromCircle(center: dropPosition, radius: layout.gridTileSize / 2);
          this.animatedGridTiles.add(AnimatedGridTile(dt.gridCoord!, srcRect));
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
    Rect startRect = Rect.fromCircle(center: startPos, radius: layout.rackTileSize / 2);
    this.animatedRackTiles.add(AnimatedRackTile(rt, startRect));
  }

  bool allTilesPlacedInSingleGroup() {
    final groups = this.grid.connectedLetterGroups();
    return (groups.length == 1 && groups[0].length == this.lettersInGame);
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
    if (allTilesPlacedInSingleGroup() && computeInvalidLetterCoords().isEmpty) {
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

  Widget letterTile(String letter, double cellSize, GridRules rules, {legality = TileLegality.legal}) {
    final background = tileBackgroundColors[legality];
    // Setting height to 0 is necessary to center the letter in the tile.
    final tileContent = (letter == "Q" && rules.qHandling == QTileHandling.qOrQu) ?
        Text("Q/QU", textAlign: TextAlign.center, style: TextStyle(color: tileTextColor, fontSize: cellSize * 0.4, height: 0))
        :
        Text(letter, textAlign: TextAlign.center, style: TextStyle(color: tileTextColor, fontSize: cellSize * 0.8, height: 0));
    return Container(width: cellSize, height: cellSize,
        decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(cellSize * 0.15),
            border: Border.all(
                color: tileBorderColor,
                width: cellSize * 0.02,
            ),
        ),
        child: tileContent);
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
        return allTilesPlacedInSingleGroup();
    }
  }

  List<Widget> gridTiles(final Layout layout) {
    final List<Widget> tiles = [];
    final showIllegal = shouldHighlightIllegalWords();
    final groups = grid.connectedLetterGroups();
    for (var y = 0; y < grid.numYCells(); y++) {
      for (var x = 0; x < grid.numXCells(); x++) {
        if (!grid.isEmptyAtXY(x, y)) {
          bool isTranslucent =
              (this.dragTile != null && Coord.isAtXY(this.dragTile!.gridCoord, x, y)) ||
                  !this.animatedGridTiles.every((a) => !Coord.isAtXY(a.destination, x, y));
          double opacity = isTranslucent ? 0.2 : 1.0;
          final pos = layout.offsetForGridXY(x, y);
          final coord = Coord(x, y);
          final legality =
              showIllegal && this.invalidLetterCoords.contains(coord)
                  ? TileLegality.invalid_word :
                    showIllegal && !groups[0].contains(coord)
                        ? TileLegality.disconnected_group : TileLegality.legal;
          tiles.add(Transform.translate(offset: pos, child: Opacity(opacity: opacity, child: GestureDetector(
              onPanStart: (event) => gridTileDragStart(event, x, y),
              onPanUpdate: gridTileDragUpdate,
              onPanEnd: gridTileDragEnd,
              child: letterTile(grid.atXY(x, y), layout.gridTileSize, rules, legality: legality)))));
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
          child: letterTile(rt.letter, layout.rackTileSize, rules)
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

  Widget dragTargetHighlight(final Layout layout) {
    final target = _gridCoordForDragTileCurrentPosition(layout);
    if (target == null || !grid.isEmptyAtXY(target.x, target.y)) {
      return SizedBox();
    }
    final gridLineOffset = Offset(layout.gridLineWidth, layout.gridLineWidth);
    final offset = layout.offsetForGridXY(target.x, target.y) + layout.gridRect.topLeft - gridLineOffset;
    final borderWidth = layout.gridTileSize / 16;
    return Transform.translate(offset: offset, child: Container(
      height: layout.gridTileSize + 2 * layout.gridLineWidth,
      width: layout.gridTileSize + 2 * layout.gridLineWidth,
      decoration: BoxDecoration(border: Border.all(width: borderWidth, color: Colors.blue)),
    ));
  }

  Widget animatedRackTileWidget(final AnimatedRackTile animTile, final Layout layout) {
    final animationDone = () {
      this.animatedRackTiles.remove(animTile);
      this.rackTiles.remove(animTile.tile);
      this.rackTiles.add(animTile.tile);
    };

    final endOffset = layout.rackRect.topLeft + rackTilePosition(animTile.tile, layout);
    final destRect = Rect.fromLTWH(endOffset.dx, endOffset.dy, layout.rackTileSize, layout.rackTileSize);
    return TweenAnimationBuilder(
      tween: RectTween(begin: animTile.origin, end: destRect),
      curve: Curves.ease,
      duration: Duration(milliseconds: newTileSlideInAnimationMillis),
      onEnd: animationDone,
      builder: (BuildContext context, Rect? rect, Widget? child) {
        return Positioned(
          left: rect!.left,
          top: rect!.top,
          child: letterTile(animTile.tile.letter, rect.width, rules),
        );
      },
    );
  }

  Widget animatedGridTileWidget(final AnimatedGridTile animTile, final Layout layout) {
    final animationDone = () {
      setState(() {
        this.animatedGridTiles.remove(animTile);
      });
    };

    final destCoord = animTile.destination;
    final endOffset = layout.offsetForGridXY(destCoord.x, destCoord.y) + layout.gridRect.topLeft;
    final destRect = Rect.fromLTWH(endOffset.dx, endOffset.dy, layout.gridTileSize, layout.gridTileSize);
    final letter = grid.atXY(destCoord.x, destCoord.y);
    return TweenAnimationBuilder(
      tween: RectTween(begin: animTile.origin, end: destRect),
      curve: Curves.ease,
      duration: Duration(milliseconds: 300),
      onEnd: animationDone,
      builder: (BuildContext context, Rect? rect, Widget? child) {
        return Positioned(
          left: rect!.left,
          top: rect!.top,
          child: letterTile(letter, rect.width, rules),
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
    final buttonScale = max(1.0, layout.statusRect.height / 60);
    return Positioned(
        left: layout.statusRect.left,
        top: layout.statusRect.top,
        width: layout.statusRect.width,
        height: layout.statusRect.height,
        child: Container(
          color: statusBackgroundColor,
          child: Row(children: [
            Container(width: layout.statusRect.width * 0.05),
            Text("${this.grid.numberOfFilledCells()} / ${this.lettersInGame}", style: TextStyle(fontSize: fontSize)),
            Expanded(child: Container()),
            Text(formattedElapsedTime(), style: TextStyle(fontSize: fontSize)),
            Expanded(child: Container()),
            Transform.scale(scale: buttonScale, child: ElevatedButton(onPressed: _showMenu, child: Text("Menu"))),
            Container(width: layout.statusRect.width * 0.05),
          ]),
        )
      );
  }

  Widget dragTileWidget(final Layout layout) {
    final tileSize = this.dragTile!.rackTile != null ? layout.rackTileSize : layout.gridTileSize;
    return Positioned(
        left: this.dragTile!.currentPosition.dx - tileSize / 2,
        top: this.dragTile!.currentPosition.dy - tileSize / 2,
        child: letterTile(this.dragTile!.letter, tileSize, rules));
  }

  Widget _paddingAll(final double paddingPx, final Widget child) {
    return Padding(padding: EdgeInsets.all(paddingPx), child: child);
  }

  TableRow makeButtonRow(String title, void Function() onPressed) {
    return TableRow(children: [
      Padding(
        padding: EdgeInsets.all(8),
        child: ElevatedButton(
          onPressed: onPressed,
          child: Text(title),
        ),
      ),
    ]);
  }

  Widget _mainMenuDialog(final BuildContext context, final Size displaySize) {
    final minDim = displaySize.shortestSide;
    final scale = (minDim / 450).clamp(1.0, 1.5);
    return Transform.scale(scale: scale, child: Container(
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
                    fontSize: 24,
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
    )));
  }

  Widget _gameOverDialog(final BuildContext context, final Size displaySize) {
    final minDim = displaySize.shortestSide;
    final scale = (minDim / 450).clamp(1.0, 1.5);

    final bestTimes = readBestTimesFromPrefs(bestTimesPrefsKey(this.lettersInGame));
    final padding = (minDim * 0.05).clamp(5.0, 10.0);

    final bestTimeTableRow = (GameTimeRecord record) {
      final elapsedTimeStr = formattedMinutesSecondsFromMillis(record.elapsedMillis);
      final gameTime = DateTime.fromMillisecondsSinceEpoch(record.timestampMillis);
      final gameDateStr = DateFormat.yMMMd().format(gameTime);
      final isFromLastGame = this.gameStopwatch.elapsedMilliseconds == record.elapsedMillis;
      final textStyle = TextStyle(
        fontSize: 18,
        color: isFromLastGame ? Colors.blue[700] : Colors.black,
      );
      return TableRow(children: [
        _paddingAll(5, Text(elapsedTimeStr, style: textStyle)),
        _paddingAll(5, Container(width: minDim * 0.02)),
        _paddingAll(5, Text(gameDateStr, style: textStyle)),
      ]);
    };

    return Transform.scale(scale: scale, child: Container(
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Dialog(
          backgroundColor: dialogBackgroundColor,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _paddingAll(15, Text(
                  'Finished in ${formattedElapsedTime()}!',
                  style: TextStyle(
                    fontSize: 24,
                  )
              )),

              if (bestTimes.isNotEmpty) ...[
                _paddingAll(10, Text(
                    "Best Times (${this.lettersInGame} tiles)",
                    style: TextStyle(
                      fontSize: 20,
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
    ));
  }

  Widget _preferencesDialog(final BuildContext context, final Size displaySize) {
    final scale = (displaySize.shortestSide / 450).clamp(1.0, 1.5);

    final titleFontSize = 24.0;
    final baseFontSize = 16.0;
    final numTilesInGame = readNumTilesPerGameFromPrefs();

    final makeGameLengthRow = () {
      final menuItemStyle = TextStyle(
          fontSize: baseFontSize,
          fontWeight: FontWeight.normal,
          color: Colors.blue[700],
      );
      return _paddingAll(0, Row(children:[
        Text('Game length:', style: TextStyle(fontSize: 16)),
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

    final makeQRow = () {
      return TableRow(children: [CheckboxListTile(
        dense: true,
        title: Text("Q can be used as QU", style: TextStyle(fontSize: baseFontSize)),
        isThreeLine: false,
        onChanged: (bool? checked) async {
          final q = checked == true ? QTileHandling.qOrQu : QTileHandling.qOnly;
          setState(() {
            rules.qHandling = q;
            if (gameMode == GameMode.in_progress) {
              invalidLetterCoords = computeInvalidLetterCoords();
            }
          });
          SharedPreferences prefs = await SharedPreferences.getInstance();
          prefs.setString(qHandlingPrefsKey, q.toString());
        },
        value: rules.qHandling == QTileHandling.qOrQu,
      )]);
    };

    return Transform.scale(scale: scale, child: Container(
        width: double.infinity,
        height: double.infinity,
        child: Center(
          child: Dialog(
            backgroundColor: dialogBackgroundColor,
            child: Padding(padding: EdgeInsets.all(20),
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
                          TableRow(children: [SizedBox(height: 10)]),
                          TableRow(children: [makeGameLengthRow()]),
                          TableRow(children: [SizedBox(height: 10)]),
                          TableRow(children: [Text('Highlight invalid words:', style: TextStyle(fontSize: baseFontSize))]),
                          makeIllegalHighlightOptionRow("Always", IllegalWordHighlightMode.always),
                          makeIllegalHighlightOptionRow('When all tiles are placed', IllegalWordHighlightMode.all_tiles_played),
                          makeIllegalHighlightOptionRow('Never', IllegalWordHighlightMode.never),
                          TableRow(children: [SizedBox(height: 5)]),
                          makeQRow(),
                        ],
                      ),
                      SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _closePreferences,
                        child: Text('OK'),
                      )
                    ],
                  ),
                ],
              ),
            ),
          ),
        )));
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
      applicationName: appTitle,
      applicationVersion: appVersion,
      applicationLegalese: appLegalese,
      children: [
        Container(height: 15),
        MarkdownBody(
          data: aboutText,
          onTapLink: (text, href, title) => launchUrl(Uri.parse(href!)),
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
            dragTargetHighlight(layout),
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
