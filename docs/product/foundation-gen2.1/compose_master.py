"""Assemble the portable brief from the chapters; --check fails on drift."""
import json
from pathlib import Path
import re
import sys

ROOT=Path(__file__).resolve().parent
def read(name):
    return (ROOT/name).read_text(encoding='utf8').strip()

def standalone(txt):
    # No companion file is necessary to read the standalone brief.
    return re.sub(r'\[([^\]\n]+)\]\((?!https?://|#)[^\n)]+\)',r'\1',txt)

def master():
    intro="""# Room in the Cart

**Codex product and build brief · Foundation Gen 2.1 · US iPhone first release**

Room in the Cart helps a household answer one question: *If we change this pickup, can we still afford it and make the dinners and lunches we promised?* It connects a shared request list to the actual packs, checkout fees, portions, and food that comes home. It does not sell groceries. The intended first user is the person already coordinating a family's weekly shop, often across more than one phone and more than one cook.

**How to use this file.** Give this Markdown file to Codex as the product brief. It includes the complete release register, all 27 screens, visual system, role rules, calculation examples, implementation order and keyword plan. For implementation also extract the companion foundation package: it supplies the executable relational reference, adversarial tests, visual studies, historical evidence and editable keyword planner. The current workspace contains a legacy Expo scaffold, not the product. Build the iPhone app in SwiftUI, with a narrow mobile web experience for invited people. Reference fixtures are fictional.

**First instruction to Codex:** Inspect the checkout. Start B00 and B01 in a native iOS target. From the real Shop tab, let a new user compare two pack offers with no account or network. Save, kill, reopen and get the same answer. Test known and unknown quantities, accessible controls, US English and US Spanish. Report the feature IDs, changed paths, actual test results and remaining device gates. Continue with B02 only when the first slice meets its evidence gate. Preserve the full launch scope; do not start a retailer integration or publish a listing.

**Jump to:** [features](#feature-register--all-first-release-behavior-and-boundaries) · [screens](#journeys-and-screens) · [design](#appearance-behavior-and-language) · [permissions](#who-may-see-or-change-each-fact) · [architecture](#build-architecture-storage-and-operations) · [calculations](#calculation-contract) · [build order](#development-order-and-release-evidence) · [keywords](#launch-keywords-and-listing-instructions).

## The household and its first pickup

Mia is the assigned shopper. Sam finishes the cereal, types or dictates a request, reviews one box, and sends it. His own phone can say “Received”; that does not add anything to the basket. Mia sees $37.20 expected checkout, $3.49 for the box and a $38.00 whole-pickup limit. If fees and other commitments are unchanged, the new checkout is $40.69, $2.69 over. Mia can link a box already on the list, add one after review, ask Sam a question, or save it for the next trip. Sam can see his own outcome, never the price or the household's other requests.

Mia also needs six wraps for tacos, four for quesadillas and two for lunch. With eight per pack and no confirmed stock, she needs two whole packs. One delivered eight-pack with only six usable does not cover dinner: reserve the two lunches and allocate the remaining four to tacos. Two taco wraps and four quesadilla wraps remain open. Alex gets the dated, corrected cooking instruction. The source report, usable observation and lunch reservation are three different facts. Comparing a cheaper pack only matters if it supplies the same commitments and the entire checkout works.

Free supports an account-free single item, urgent repair without an order, and an entire ordinary pickup through handoff, arrival, recovery and next shop. Household is a US $49.99/year price hypothesis for repeated planning, not a hardcoded storefront price. It offers up to two named adult planning seats. A child can contribute with guardian setup; an Android cook can read a narrow web view or a dated message. Neither a seat nor a link confers checkout control. Direct retailer connectivity is deferred; copy, share, optional external open and shopper-reported placement ship.

## How to make decisions from this brief

1. Use the feature ID to determine scope and acceptance. There are 52 launch requirements, one later integration and six boundaries, for 59 registered decisions. The three owner additions are included in launch.
2. Use the screen route and role rules to decide where a user can act and what can leave the device. Unknown price, yield, fees or eligibility must remain visible. Never fill a missing quantity with zero.
3. Use stable revisions, reviewed proposals, dated files and current grants. A copy, a placed report, a retailer acknowledgment, an actual delivery and a settled charge are different events.
4. Build the ordered vertical slices; use the release gates to decide whether a claim can ship. A check passing in the reference model does not establish a working application, paid demand, accessibility or regulatory clearance.

## Feature register · all first-release behavior and boundaries
"""
    features=read('02-features.md')
    parts=[intro]
    for group in re.split(r'^## ',features,flags=re.M)[1:]:
        group_title,body=group.split('\n',1)
        parts.append('### '+group_title)
        for block in re.split('^### ',body,flags=re.M)[1:]:
            title,meta,implementation,acceptance=block.strip().split('\n\n')
            parts.append('**'+title+'**  \n'+meta+'  \n'+implementation+' '+acceptance.replace('**Accept when.**','**Acceptance:**'))
    screens=read('03-screens.md')
    parts+=['## Journeys and screens',screens[screens.index('On iPhone,'):]]
    design=read('04-design.md')
    parts+=['## Appearance, behavior and language',design[design.index('**One person'):design.index('The retained visual studies')]+design[design.index('## Color placement'):design.index('Use [the launch handoff]')]]
    service=read('07-service.md')
    parts+=['## Who may see or change each fact', service[service.index('Keep prices'):service.index('## HTTP surface')]]
    arch=read('05-architecture.md')
    parts+=['## Build architecture, storage and operations',arch[arch.index('Choose **SwiftUI'):]]
    domain=read('06-domain.md')
    parts+=['## Meals, quantities, money and files',domain[domain.index('**Common representations.**'):]]
    parts+=['## Network commands and synchronization',service[service.index('## HTTP surface'):service.index('The 20 routing and replay traces')]]
    parts+=['## Development order and release evidence',read('08-build.md').split('\n',1)[1]]
    parts+=['## Launch keywords and listing instructions',read('09-keywords.md').split('\n',1)[1]]
    parts+=['## Foundation 2 audit and limits',read('10-gen2-audit.md').split('\n',1)[1]]
    parts += [read('11-experience-audit.md').replace('# Screen placement', '## Screen placement', 1), read('12-apple-billing.md').replace('# Apple subscription', '## Apple subscription', 1)]
    parts += [service[service.index('**Live-view lifecycle.**'):]]
    return standalone('\n\n'.join(s.strip() for s in parts))+'\n'
if __name__=='__main__':
    target=ROOT/'CODEX-MASTER.md'
    if '--check' in sys.argv:
        assert target.read_text(encoding='utf8')==master(), 'Regenerate CODEX-MASTER.md with compose_master.py'
    else:
        target.write_text(master(),encoding='utf8')
