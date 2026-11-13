"""Pure reference model for the Swift control wire format and failure semantics."""
SUCCESS, FAILURE = 1 << 56, 2 << 56
MASK = (1 << 56) - 1


def command(phase, sequence, ordinal=0):
    if phase not in range(1, 6) or not 1 <= sequence <= 0xffffff or not 0 <= ordinal <= 16:
        raise ValueError('command_bounds')
    return phase | (sequence << 8) | (ordinal << 32)


def classify_ack(request, ack):
    if ack >> 56 == 2: return 'failure'
    if ack == request | SUCCESS: return 'success'
    if ack >> 56 > 2: raise ValueError('ack_encoding')
    return 'pending'


class Model:
    def __init__(self, nonce):
        self.nonce = nonce
        self.stage = 'registered'
        self.sequence = 0
        self.pending = None
        self.ack = 0
        self.active = None
        self.completed = []
        self.events = []

    def fail(self, reason, request=None):
        request = self.pending if request is None else request
        self.stage = 'failed'
        self.ack = ((request or 0) & MASK) | FAILURE
        return reason

    def success(self):
        if self.stage == 'failed' or self.pending is None: raise ValueError('false_success')
        self.ack = self.pending | SUCCESS
        self.pending = None

    def receive(self, request):
        if self.stage == 'failed': return
        if request == (self.ack & MASK) and self.ack >> 56 == 1: return  # inert re-delivery
        phase, seq, ordinal = request & 255, (request >> 8) & 0xffffff, (request >> 32) & 65535
        if request >> 48 or seq != self.sequence + 1 or self.pending is not None:
            return self.fail('sequence_or_pending', request)
        self.sequence = seq; self.pending = request
        if phase == 1 and self.stage == 'registered' and ordinal == 0:
            self.stage = 'waitingForCollector'; return
        if phase == 2 and self.stage == 'recording' and self.active is None and ordinal == len(self.completed) + 1 and ordinal <= 16:
            self.active = ordinal; self.events.append(('begin', ordinal)); self.success(); return
        if phase == 3 and self.stage == 'recording' and self.active == ordinal and ordinal == len(self.completed) + 1:
            self.events.append(('end', ordinal)); self.completed.append(ordinal); self.active = None; self.success(); return
        if phase == 4 and self.stage == 'recording' and self.active is None and self.completed and ordinal == len(self.completed):
            self.events.append(('complete', None)); self.stage = 'waitingForFinalization'; return
        return self.fail('phase', request)

    def host(self, action, nonce, current_command, ready=False, tracer_zero=False):
        # ready/tracer_zero are supervisor invariants, not facts an app can infer from a file.
        if nonce != self.nonce or current_command != self.pending or action == 'ABORT':
            return self.fail('host_nonce_abort_or_pending_change')
        if self.stage == 'waitingForCollector' and action == 'GO' and ready:
            self.stage = 'recording'; self.events.append(('ready', None)); self.success(); return
        if self.stage == 'waitingForFinalization' and action == 'Q' and tracer_zero:
            self.stage = 'finished'; self.success(); return
        return self.fail('early_or_wrong_host_phase')

    def timeout(self): return self.fail('deadline')
