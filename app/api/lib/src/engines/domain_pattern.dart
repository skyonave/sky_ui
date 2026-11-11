/// Compile a validated hostname mask to the same expression for all engines.
String domainPattern(String mask) =>
    '^${mask.replaceAll('.', r'\.').replaceAll('*', '[a-z0-9.-]*')}\$';
