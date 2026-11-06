"""Strict case boundaries and all-process integrity for one original UI02 history."""
import re
from protocol import MARKER, parse_events, parse_markers

CASES = [
    ('FreeJourneyUITests', 'testRecipeCaptureOpensOnFirstAttemptAndReopensAfterCancel'),
    ('PickupOfferUITests', 'testSavedOfferReopensAndUpdatesResponseAfterRestart'),
    ('RoomInTheCartUITests', 'testConfirmedComparisonDeletionSurvivesRestart'),
    ('RoomInTheCartUITests', 'testSpanishEntryPreservesOriginalFoodNameAndSavedAnswer'),
]
SELECTORS = ['RoomInTheCartUITests/' + '/'.join(case) for case in CASES]
BOUNDARY = re.compile(r"Test Case '-\[RoomInTheCartUITests\.([^ ]+) ([^]]+)\]' (started\.|(passed|failed) \(([0-9.]+) seconds\)\.)$")


class CaseLog:
    def __init__(self):
        self.active = None
        self.cases = []
        self.errors = []
        self.line = 0

    def feed(self, line):
        self.line += 1
        if 'Restarting after unexpected exit' in line:
            self.errors.append('XCTest runner restart at line ' + str(self.line))
        match = BOUNDARY.fullmatch(line.rstrip('\n'))
        started_target = False
        if line.startswith('Test Case ') and match is None:
            self.errors.append('Unrecognized test boundary at line ' + str(self.line))
        if match:
            case = (match[1], match[2])
            if match[3] == 'started.':
                if self.active is not None or len(self.cases) >= 4 or case != CASES[len(self.cases)]:
                    self.errors.append('Unexpected/duplicate/interleaved case start at line ' + str(self.line))
                item = {'case': list(case), 'startLine': self.line, 'markers': [], 'terminations': [], 'outcome': None}
                self.cases.append(item)
                self.active = item
                started_target = case == CASES[-1] and not self.errors
            elif self.active is None or tuple(self.active['case']) != case:
                self.errors.append('Unmatched case end at line ' + str(self.line))
            else:
                self.active.update(endLine=self.line, outcome=match[4], durationSeconds=float(match[5]))
                self.active = None
        if 'SDD_RUNNER|' in line:
            if self.active is None or tuple(self.active['case']) not in CASES[2:]:
                self.errors.append('Marker outside an instrumented selected case at line ' + str(self.line))
            else:
                self.active['markers'].append(line.rstrip('\n'))
        termination = re.search(r'Terminate dev\.roominthecart\.app\.debug:([1-9][0-9]*)', line)
        if termination and self.active is not None:
            self.active['terminations'].append({'pid': int(termination[1]), 'line': self.line,
                                                'markerCount': len(self.active['markers'])})
        return started_target

    def proof(self):
        errors = list(self.errors)
        if [tuple(c['case']) for c in self.cases] != CASES or self.active is not None or any(c['outcome'] is None for c in self.cases):
            errors.append('Missing case/start/end; four complete ordered cases required')
        return {'complete': not errors, 'errors': errors, 'cases': self.cases}


def parse_cases(text):
    ledger = CaseLog()
    for line in text.splitlines(True):
        ledger.feed(line)
    return ledger


def compare_history(journals, live, exported, tests):
    # Validate every PID before any case or time selection; never slice sequences.
    if not 1 <= len(journals) <= 8:
        raise ValueError('Missing/excessive journals')
    records, pids = [], set()
    for name, text in journals.items():
        events = parse_events(text, journal=True)
        pid = events[0][0]
        if name != f'process-{pid}.events' or pid in pids:
            raise ValueError('Journal filename/process mismatch')
        pids.add(pid)
        records.extend(events)
    if any(sorted(parse_events(sink)) != sorted(records) for sink in (live, exported)):
        raise ValueError('All-process live/export/journal sequences disagree')
    proof = parse_cases(tests).proof()
    if not proof['complete']:
        raise ValueError('; '.join(proof['errors']))
    # These exact unchanged cases each type bQuantity once. No last-pair guessing.
    predecessor = parse_markers('\n'.join(proof['cases'][2]['markers']))
    target = parse_markers('\n'.join(proof['cases'][3]['markers']))
    if target[0][1] != predecessor[1][1] or target[0][2] <= predecessor[1][2]:
        raise ValueError('Target markers do not follow the completed predecessor')
    lower, upper = predecessor[1][2], target[0][2]
    activations = {e[0]: e[2] for e in records if e[1] == 1}
    candidates = {e[0] for e in records if e[3:] == ('comparison.focus.bQuantity', 'comparison')
                  and lower < activations[e[0]] <= e[2] <= upper}
    # Also reject old-process focus in this interval, not just new-PID candidates.
    focused = {e[0] for e in records if e[3:] == ('comparison.focus.bQuantity', 'comparison') and lower < e[2] <= upper}
    if len(candidates) != 1 or candidates != focused:
        raise ValueError('Target app PID is missing or ambiguous across case marker interval')
    pid = next(iter(candidates))
    terminations = [item for item in proof['cases'][3]['terminations'] if item['markerCount'] >= 2]
    if not terminations or terminations[0]['pid'] != pid:
        raise ValueError(f'Target PID {pid} candidate in interval {lower}..{upper} lacks matching first post-marker Spanish termination')
    if not any(e[0] == pid and e[2] > target[1][2] for e in records):
        raise ValueError('No target-process post-return coverage')
    return {'processIDs': sorted(pids), 'targetProcessID': pid, 'events': len(records),
            'predecessorMarkers': predecessor, 'markers': target, 'sequence': proof,
            'absenceInferenceAllowed': False, 'causalConclusion': None}


def candidate_evidence(journals, tests):
    """Retain partial candidate reasoning without promoting it to attribution."""
    proof = parse_cases(tests).proof()
    result = {'sequence': proof, 'attributionComplete': False, 'absenceInferenceAllowed': False,
              'causalConclusion': None}
    try:
        preceding = [case for case in proof['cases'] if tuple(case['case']) == CASES[2]]
        target = [case for case in proof['cases'] if tuple(case['case']) == CASES[3]]
        if len(preceding) != 1 or len(target) != 1 or preceding[0]['outcome'] is None:
            raise ValueError('No unique completed predecessor and started target')
        lower = parse_markers('\n'.join(preceding[0]['markers']))[-1][2]
        before = [MARKER.fullmatch(line) for line in target[0]['markers'] if line.startswith('SDD_RUNNER|before|')]
        if len(before) != 1 or before[0] is None:
            raise ValueError('No unique valid target before marker')
        upper = float(before[0][3])
        records = [event for text in journals.values() for event in parse_events(text, journal=True)]
        activations = {e[0]: e[2] for e in records if e[1] == 1}
        result.update(predecessorAfter=lower, targetBefore=upper,
            candidatePIDs=sorted({e[0] for e in records if e[3:] == ('comparison.focus.bQuantity', 'comparison')
                                  and lower < activations[e[0]] <= e[2] <= upper}),
            targetTerminations=target[0]['terminations'],
            limitation='Candidates only; full all-sink comparison, markers, case completion and termination corroboration are required separately')
    except (ValueError, KeyError) as error:
        result['error'] = str(error)
    return result
