// Copyright 2013 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/** Splits full compilation log into IR and native code artifacts. */
library modes.dartvm.preparser;

import 'package:irhydra/src/modes/dartvm/name_parser.dart' as name_parser;
import 'package:irhydra/src/modes/ir.dart' as IR;

canRecognize(text) =>
  text.contains("*** BEGIN CFG") || text.contains("*** BEGIN CODE");

/** Preparse given dump extracting information about compiled functions. */
parse(str) {
  // Matches tags that start/end cfg and code dumps.
  final tagRe = new RegExp(r"\*\*\* (BEGIN|END) (CFG|CODE)\n");

  // Matches name of the function printed in a flow graph dump.
  final cfgNameRe = new RegExp(r"^==== (.*)$");

  // Matches name of the function printed in a code dump.
  final codeNameRe = new RegExp(r"'(.*)' {$");

  // List of all functions and the last one.
  final functions = <IR.Method>[];

  // Create a new function if needed.
  createFunction(name, {phaseName}) {
    if (functions.isEmpty ||
        functions.last.name.full != name ||
        functions.last.phases.last.name == phaseName ||
        functions.last.phases.last.name == "After Optimizations" ||
        functions.last.phases.last.code != null) {
      final function = new IR.Method(name_parser.parse(name));
      functions.add(function);
    }
    return functions.last;
  }

  // Start position of the current record.
  var start;

  // Find all tags in the string.
  for (var match in tagRe.allMatches(str)) {
    final tag = match.group(0);

    if (tag.startsWith("*** B")) {
      start = match.end;  // Just remember the start and wait for the end tag.
    } else if (tag == "*** END CFG\n") {
      // Control flow graph dump.

      // Extract the phase name from the first line.
      final firstLF = str.indexOf("\n", start);
      final phaseName = str.substring(start, firstLF);

      // Extract the function name from the second line.
      final secondLF = str.indexOf("\n", firstLF + 1);
      final secondLine = str.substring(firstLF + 1, secondLF);
      final name = cfgNameRe.firstMatch(secondLine).group(1);

      // Create a phase with substring thunk for an IR.
      final substr = _deferSubstring(str, secondLF + 1, match.start);
      final phase = new IR.Phase(phaseName, ir: substr);

      createFunction(name, phaseName: phaseName).phases.add(phase);
    } else if (tag == "*** END CODE\n") {
      // Code dump.
      final substr = _deferSubstring(str, start, match.start);

      // Extract function name from the first line of the code dump.
      final firstLine = str.substring(start, str.indexOf("\n", start));
      final name = codeNameRe.firstMatch(firstLine).group(1);

      // Create function to host the phase.
      final function = createFunction(name, phaseName: "Code");
      if (!function.phases.isEmpty) {
        function.phases.last.code = substr;
      } else {
        function.phases.add(new IR.Phase("Code", code: substr));
      }
    }
  }

  return functions;
}

/** Create substring thunk. */
_deferSubstring(str, start, end) =>
  () => str.substring(start, end);