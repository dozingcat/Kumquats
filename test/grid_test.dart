import 'package:flutter_test/flutter_test.dart';
import 'package:kumquats/grid.dart';

void main() {
  test("set letters", () {
    final grid = LetterGrid(10, 15);
    expect(grid.numXCells(), 10);
    expect(grid.numYCells(), 15);

    grid.setAtXY(3, 6, "X");
    grid.setAtXY(4, 7, "Y");
    grid.setAtXY(5, 8, "Z");
    grid.setAtXY(3, 6, "A");

    expect(grid.atXY(3, 6), "A");
    expect(grid.atXY(4, 7), "Y");
    expect(grid.atXY(5, 8), "Z");

    expect(grid.atXY(3, 5), "");
    expect(grid.isEmptyAtXY(3, 5), true);
    expect(grid.isEmptyAtXY(3, 6), false);

    expect(grid.numberOfFilledCells(), 3);
  });

  test("find words", () {
    final grid = LetterGrid(10, 10);
    grid.setAtXY(2, 3, "C");
    grid.setAtXY(2, 5, "T");
    grid.setAtXY(2, 4, "A");
    grid.setAtXY(3, 3, "U");
    grid.setAtXY(4, 3, "P");
    grid.setAtXY(4, 4, "I");
    grid.setAtXY(6, 6, "X");

    final words = grid.findWords();
    expect(words.length, 3);
    expect(words.contains(GridWord(Coord(2, 3), Direction.Vertical, "CAT")), true);
    expect(words.contains(GridWord(Coord(2, 3), Direction.Horizontal, "CUP")), true);
    expect(words.contains(GridWord(Coord(4, 3), Direction.Vertical, "PI")), true);
  });

  test("connected groups", () {
    final grid = LetterGrid(10, 10);
    expect(grid.connectedLetterGroups().length, 0);

    grid.setAtXY(2, 3, "C");
    grid.setAtXY(2, 5, "T");
    grid.setAtXY(2, 4, "A");
    grid.setAtXY(3, 3, "U");
    grid.setAtXY(4, 3, "P");
    grid.setAtXY(4, 4, "I");
    expect(grid.connectedLetterGroups().length, 1);

    grid.setAtXY(6, 6, "X");
    expect(grid.connectedLetterGroups().length, 2);
  });

  test("check words", () {
    final validWords = {"ACE", "CAT", "ETA"};
    final grid = LetterGrid(10, 10);
    final rules = GridRules(qHandling: QTileHandling.qOnly);
    expect(grid.coordinatesWithInvalidWords(validWords, rules).length, 0);

    grid.setAtXY(2, 5, "A");
    grid.setAtXY(3, 5, "C");
    grid.setAtXY(4, 5, "E");
    grid.setAtXY(2, 6, "C");
    grid.setAtXY(3, 6, "A");
    grid.setAtXY(4, 6, "T");
    grid.setAtXY(2, 7, "E");
    grid.setAtXY(3, 7, "T");
    grid.setAtXY(4, 7, "A");
    expect(grid.coordinatesWithInvalidWords(validWords, rules).length, 0);

    grid.setAtXY(3, 7, "X");
    expect(
        grid.coordinatesWithInvalidWords(validWords, rules),
        {Coord(3, 5), Coord(3, 6), Coord(3, 7), Coord(2, 7), Coord(4, 7)});
  });

  try {
    try {
      test("check words with Q/QU", () {
        final validWords = {"QUART", "QAT","EQUIVOQUE"};
        final grid = LetterGrid(10, 10);
        final qOnlyRules = GridRules(qHandling: QTileHandling.qOnly);
        final qOrQuRules = GridRules(qHandling: QTileHandling.qOrQu);

        // EQUIVOQUE without U letters.
        grid.setAtXY(1, 4, "E");
        grid.setAtXY(2, 4, "Q");
        grid.setAtXY(3, 4, "I");
        grid.setAtXY(4, 4, "V");
        grid.setAtXY(5, 4, "O");
        grid.setAtXY(6, 4, "Q");
        grid.setAtXY(7, 4, "E");
        // QUART without Q.
        grid.setAtXY(2, 5, "A");
        grid.setAtXY(2, 6, "R");
        grid.setAtXY(2, 7, "T");
        // QAT
        grid.setAtXY(6, 5, "A");
        grid.setAtXY(6, 6, "T");

        expect(
            grid.coordinatesWithInvalidWords(validWords, qOnlyRules), {
              Coord(1, 4), Coord(2, 4), Coord(3, 4), Coord(4, 4), Coord(5, 4),
              Coord(6, 4), Coord(7, 4), Coord(2, 5), Coord(2, 6), Coord(2, 7),
            });
        expect(grid.coordinatesWithInvalidWords(validWords, qOrQuRules).length, 0);
      });
    } catch (e, s) {
      print(s);
    }
  } catch (e, s) {
    print(s);
  }
}
