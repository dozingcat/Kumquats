enum Direction {Horizontal, Vertical}

enum GridEdge {Top, Left, Right, Bottom}

enum QTileHandling {qOnly, qOrQu}

class GridRules {
  QTileHandling qHandling;

  GridRules({required this.qHandling});
}

class Coord {
  final int x;
  final int y;

  Coord(this.x, this.y);

  static bool isAtXY(Coord? c, int x, int y)  => c != null && c.x == x && c.y == y;

  bool operator ==(o) => o is Coord && x == o.x && y == o.y;

  int get hashCode => x.hashCode ^ y.hashCode;

  @override String toString() => "Coord($x, $y)";
}

class GridWord {
  final Coord start;
  final Direction direction;
  final String word;

  GridWord(this.start, this.direction, this.word);

  bool operator ==(o) => o is GridWord
      && start == o.start
      && direction == o.direction
      && word == o.word;

  int get hashCode => start.hashCode ^ direction.hashCode ^ word.hashCode;
}

class LetterGrid {
  late List<List<String>> cells;

  LetterGrid(int numX, int numY) {
    cells = [];
    for (int i = 0; i < numY; i++) {
      cells.add(List.filled(numX, "", growable: true));
    }
  }

  int numXCells() {
    return cells[0].length;
  }

  int numYCells() {
    return cells.length;
  }

  String atXY(int x, int y) {
    return cells[y][x];
  }

  bool isEmptyAtXY(int x, int y) {
    return cells[y][x].isEmpty;
  }

  void setAtXY(int x, int y, String letter) {
    cells[y][x] = letter;
  }

  int numberOfFilledCells() {
    int filled = 0;
    for (var y = 0; y < numYCells(); y++) {
      final row = cells[y];
      for (var x = 0; x < numXCells(); x++) {
        if (row[x].isNotEmpty) {
          filled += 1;
        }
      }
    }
    return filled;
  }

  List<GridWord> findWords() {
    List<GridWord> words = [];
    for (var y = 0; y < numYCells() - 1; y++) {
      for (var x = 0; x < numXCells() - 1; x++) {
        var letter = atXY(x, y);
        if (letter.isNotEmpty) {
          // Check horizontal.
          if (x == 0 || isEmptyAtXY(x - 1, y)) {
            var word = letter;
            var x2 = x + 1;
            while (x2 < numXCells() && !isEmptyAtXY(x2, y)) {
              word += atXY(x2, y);
              x2 += 1;
            }
            if (word.length > 1) {
              words.add(GridWord(Coord(x, y), Direction.Horizontal, word));
            }
          }
          // Check vertical.
          if (y == 0 || isEmptyAtXY(x, y - 1)) {
            var word = letter;
            var y2 = y + 1;
            while (y2 < numYCells() && !isEmptyAtXY(x, y2)) {
              word += atXY(x, y2);
              y2 += 1;
            }
            if (word.length > 1) {
              words.add(GridWord(Coord(x, y), Direction.Vertical, word));
            }
          }
        }
      }
    }
    return words;
  }

  void extendEdge(GridEdge edge, int numToAdd) {
    switch (edge) {
      case GridEdge.Bottom:
        for (int i = 0; i < numToAdd; i++) {
          this.cells.add(List.filled(numXCells(), "", growable: true));
        }
        break;
      case GridEdge.Top:
        for (int i = 0; i < numToAdd; i++) {
          this.cells.insert(0, List.filled(numXCells(), "", growable: true));
        }
        break;
      case GridEdge.Right:
        for (int y = 0; y < numYCells(); y++) {
          this.cells[y].addAll(List.filled(numToAdd, ""));
        }
        break;
      case GridEdge.Left:
        for (int y = 0; y < numYCells(); y++) {
          this.cells[y].insertAll(0, List.filled(numToAdd, ""));
        }
        break;
    }
  }

  Set<Coord> _connectedCoords(final Coord start, final Set<Coord> seen) {
    Set<Coord> group = {};
    var queue = [start];
    while (queue.isNotEmpty) {
      final c = queue.removeAt(0);
      group.add(c);
      seen.add(c);
      if (c.x > 0 && !isEmptyAtXY(c.x - 1, c.y)) {
        final left = Coord(c.x - 1, c.y);
        if (!seen.contains(left)) {
          queue.add(left);
        }
      }
      if (c.y > 0 && !isEmptyAtXY(c.x, c.y - 1)) {
        final up = Coord(c.x, c.y - 1);
        if (!seen.contains(up)) {
          queue.add(up);
        }
      }
      if (c.x < numXCells() - 1 && !isEmptyAtXY(c.x + 1, c.y)) {
        final right = Coord(c.x + 1, c.y);
        if (!seen.contains(right)) {
          queue.add(right);
        }
      }
      if (c.y < numYCells() - 1 && !isEmptyAtXY(c.x, c.y + 1)) {
        final down = Coord(c.x, c.y + 1);
        if (!seen.contains(down)) {
          queue.add(down);
        }
      }
    }
    return group;
  }

  // Returns a list of sets of coordinates that form connected groups.
  // The groups are sorted by descending size.
  List<Set<Coord>> connectedLetterGroups() {
    List<Set<Coord>> groups = [];
    Set<Coord> seen = {};
    for (var y = 0; y < numYCells(); y++) {
      for (var x = 0; x < numXCells(); x++) {
        if (!isEmptyAtXY(x, y)) {
          final coord = Coord(x, y);
          if (!seen.contains(coord)) {
            groups.add(_connectedCoords(coord, seen));
          }
        }
      }
    }
    groups.sort((g1, g2) => g2.length.compareTo(g1.length));
    return groups;
  }

  bool isLegalWord(String word, Set<String> dictionary, GridRules rules) {
    if (dictionary.contains(word)) {
      return true;
    }
    if (rules.qHandling != QTileHandling.qOrQu) {
      return false;
    }
    // Assuming there's a maximum of 2 occurrences of Q.
    int qStart = word.indexOf("Q");
    if (qStart == -1) {
      return false;
    }
    String firstQu = word.substring(0, qStart) + "QU" + word.substring(qStart + 1);
    if (dictionary.contains(firstQu)) {
      return true;
    }
    int qEnd = word.lastIndexOf("Q");
    if (qEnd > qStart) {
      String secondQuNotFirst = word.substring(0, qEnd) + "QU" + word.substring(qEnd + 1);
      if (dictionary.contains(secondQuNotFirst)) {
        return true;
      }
      String secondAndFirstQu =
          word.substring(0, qStart) + "QU" + word.substring(qStart + 1, qEnd) + "QU" + word.substring(qEnd + 1);
      if (dictionary.contains(secondAndFirstQu)) {
        return true;
      }
    }
    return false;
  }

  Set<Coord> coordinatesWithInvalidWords(Set<String> validWords, GridRules rules) {
    Set<Coord> result = {};
    findWords().forEach((gw) {
      if (!isLegalWord(gw.word, validWords, rules)) {
        switch (gw.direction) {
          case Direction.Horizontal:
            for (var i = 0; i < gw.word.length; i++) {
              result.add(Coord(gw.start.x + i, gw.start.y));
            }
            break;
          case Direction.Vertical:
            for (var i = 0; i < gw.word.length; i++) {
              result.add(Coord(gw.start.x, gw.start.y + i));
            }
        }
      }
    });
    return result;
  }
}
