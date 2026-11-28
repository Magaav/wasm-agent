#!/bin/bash
. "$(cd "$(dirname "${WA_FACTORY_ORIG:-$0}")" && pwd)/lib/refresh-self.sh"   # refresh the clone between iterations
while :; do wa_factory_refresh_self;  python3 -I $HOME/Work/missions/_orch/harvest-what-hurt.py >/dev/null 2>&1; sleep 1800; done
