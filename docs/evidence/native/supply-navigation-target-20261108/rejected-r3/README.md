# R3: accessibility-frame assertion fails before Done

The candidate covers both dinner-idea and ingredient-supply editing with native
navigation Done controls. Its build and compiled-app check pass. The original
English journey fails before the first Done tap on the existing assertion:
the reported accessibility frame height is36points despite the minimum44-point
SwiftUI label. Native65/strict1 and zero observed idle messages are retained.
This is not a keyboard repair, complete journey, or successful target qualification.

Root and helper reviewed the retained before screenshot and geometry. Done and
Back are visible and separate; the blank amount is retained. Done's reported
frame is(314,66,68,36), inside a(0,62,402,54) navigation bar. A centered44×44
region fits inside that bar, but its touch behavior has not been measured.

The earlier inference that a36-point automation frame necessarily means a
sub44-point touch target is unproven. Apple's [button guidance](https://developer.apple.com/design/human-interface-guidelines/buttons)
describes a hit region. The [automation frame](https://developer.apple.com/documentation/xcuiautomation/xcuielementattributes/frame)
and UIKit [hit testing](https://developer.apple.com/documentation/uikit/uiview/hittest(_:with:))
are separate API concepts. A frame-only rejection must not be silently converted
to a pass, but another arbitrary size/style change is not yet justified either.

Next: a bounded observation of the unchanged control's actual hit testing, with
unique semantic control identity and explicit unknown results for ambiguous
ownership. Point samples would establish only their observed routing; they do
not prove action execution or every continuous point. No such probe has run.
Original results and prior source/products remain verified unchanged.
