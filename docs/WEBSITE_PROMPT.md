# Prompt for the Curated Design website: add Locis

Paste everything below the line into a session opened on the Curated Design website
project. It follows the pattern the site already uses for the other apps
(`/apps/<app>/`, `/apps/<app>/privacy/`, `/apps/<app>/support/`).

Before publishing, check the two points marked **CHECK** in the privacy text.

---

Add a new app, **Locis**, to the Curated Design website, following exactly the
structure, layout, components and tone already used for the existing apps. Use the
Curiosity Tracker pages as the template (`/apps/curiosity-tracker/`,
`/apps/curiosity-tracker/privacy/`, `/apps/curiosity-tracker/support/`). Do not
invent a new design. British English throughout.

## Pages to create

1. `/apps/locis/` (app page)
2. `/apps/locis/privacy/` (privacy policy)
3. `/apps/locis/support/` (support)

Also:

- Add Locis to the `/apps/` listing as item **06**, in the same card format as the
  others.
- Add the three new URLs to `sitemap.xml`.
- Add Locis wherever the other apps are listed in shared navigation or footers
  (for example the "App Support & Tools" links).
- There is no App Store link yet. Do not add one or a placeholder for one.
- The other apps show three screenshots each on `/apps/`. I will supply Locis
  screenshots separately. Until then, use the logo at
  `/Users/joshgourgey/Coding/Locis/Logo/logo.svg` (also `logo.png`) in whatever way
  the template handles an app without screenshots, or ask me.

## About the app (for your understanding; do not paste this section verbatim)

Locis is a free iPhone app for the UK, starting with London. You search for a place
or move the map, choose when you will arrive and leave, and the kerbs are coloured
by whether you may legally park there for the whole of that stay. Tapping a kerb
explains the rule. It does not show whether a space is empty.

- iPhone only, iOS 18 or later.
- Free. No account, no adverts, no subscriptions, no analytics, no tracking.
- Parking rules come from the Department for Transport's Digital Traffic Regulation
  Order (D-TRO) service, under the Open Government Licence v3.0.
- Coverage depends on which councils have published their orders. Where there is no
  data the app shows nothing or grey, which never means parking is unrestricted.

## 1. App page: `/apps/locis/`

Same sections as the Curiosity Tracker app page.

**Title:** Locis

**Category label for the `/apps/` listing:** Parking

**One-line description for the `/apps/` listing:**
A free iPhone app that shows whether you can legally park on a UK kerb for your
whole stay, using open government data.

**Opening description:**
Locis shows where you can legally park for the whole of your stay. Choose when you
will arrive and leave, and the kerbs around your destination are coloured by what
the published traffic orders allow: free, paid, permit holders, reserved bays, or
not allowed. It is guidance, not a guarantee, and it does not show whether a space
is free.

**App information:**

- Support: info@curateddesign.studio
- Platform: iPhone (iOS 18 or later)
- Price: Free
- Coverage: UK, starting with London. Depends on which councils have published
  their traffic orders
- Data: Department for Transport D-TRO service. Contains public sector information
  licensed under the Open Government Licence v3.0
- Privacy: No account, adverts, tracking or analytics
- Last updated: use the date you publish the page

**Support and policies:** links to `/apps/locis/privacy/` and `/apps/locis/support/`.

## 2. Privacy policy: `/apps/locis/privacy/`

Page title: `Locis Privacy Policy — Curated Design` (same pattern as the others).
Use the same heading styles as the existing privacy pages. Use the text below as
written. Set "Last updated" to the date you publish.

> **Locis Privacy Policy**
>
> Last updated: [publication date]
>
> **Overview**
>
> Locis is an iPhone app that shows whether you may legally park on a section of
> kerb for a period you choose. It is published by Curated Design Limited, a company
> registered in England and Wales (company number 16720521), Floor 1, 8 Park
> Crescent, London W1B 1PG.
>
> Locis has no accounts and does not collect personal information. Curated Design
> does not operate a server that receives your location, your searches, your chosen
> times or your settings.
>
> **Information the app uses**
>
> - **Your location**, if you allow it. Locis asks for location access only when you
>   tap the location button, and only while you are using the app. Your position is
>   used on your device to centre the map. It is not sent to Curated Design and the
>   app does not keep a history of it.
> - **Places you search for.** What you type in the search field is sent to Apple's
>   Maps service to find the place. Locis does not store your searches.
> - **Your settings.** Your vehicle type and whether you hold a Blue Badge are
>   stored on your device so the app can show which bays you can use. They are not
>   sent anywhere.
> - **The times you choose.** Arrival and leaving times are used on your device to
>   work out the parking rules. They are not sent anywhere.
>
> **How parking rules reach your device**
>
> Locis downloads parking rules as data files for the area of the map you are
> looking at, and works out the result on your device. The files are held on a web
> hosting service, currently GitHub Pages, operated by GitHub, Inc.
>
> As with any website, the hosting service receives your device's IP address and
> the names of the files requested. Each file covers an area of roughly 750 metres
> across, so the request shows the general area being viewed, not your exact
> position. Locis sends no identifier, account or precise location with these
> requests. **CHECK:** Curated Design does not receive these server logs and does
> not use them to identify anyone.
>
> Downloaded parking data is kept on your device so it does not need to be
> downloaded again.
>
> **Maps, search and directions**
>
> The map, place search and directions are provided by Apple. When you tap
> Directions, the location of the kerb you selected is passed to Apple Maps. Apple's
> handling of that information is covered by Apple's privacy policy.
>
> **No advertising, tracking or analytics**
>
> Locis contains no advertising, no third-party analytics and no tracking software.
> It does not track you across apps or websites.
>
> **Deleting your data**
>
> Everything Locis stores is on your device. Deleting the app removes your settings
> and the saved parking data. You can withdraw location access at any time in
> Settings › Privacy & Security › Location Services.
>
> **Children**
>
> Locis is not directed at children and does not knowingly collect information from
> anyone.
>
> **Where the parking information comes from**
>
> Parking rules come from the Department for Transport's Digital Traffic Regulation
> Order service and bank holiday dates from GOV.UK. Contains public sector
> information licensed under the Open Government Licence v3.0. This data describes
> roads, not people.
>
> **Contact**
>
> Questions about this policy: info@curateddesign.studio.
>
> If you are in the UK and have a concern about how your information is handled,
> you can also contact the Information Commissioner's Office at ico.org.uk.
>
> **Changes to this policy**
>
> If this policy changes, the updated version will be published on this page with a
> new date.

**CHECK before publishing:**

1. The sentence marked CHECK: confirm that the hosting account does not give you
   visitor logs. GitHub Pages does not provide them to site owners at the time of
   writing. If the data is ever moved to a host that does provide logs, or to a
   different host at all, update the hosting paragraph.
2. If the app later adds anything that sends data off the device (crash reporting,
   analytics, accounts), this policy and the App Store privacy answers must change
   first.

## 3. Support page: `/apps/locis/support/`

Same sections as the Curiosity Tracker support page: Introduction, Contact, Before
contacting support, Common issues, Deleting data, Response time.

**Introduction:** Locis shows whether you may legally park on a section of kerb for
the whole of a stay you choose, using traffic orders published by councils through
the Department for Transport.

**Contact:** info@curateddesign.studio

**Before contacting support:**

- Check you are zoomed in. Parking rules only appear at street level.
- Check your arrival and leaving times: the colours are for the whole of that period.
- Make sure the app is up to date.

**Common issues:**

- *The map shows no coloured lines where I am.* There is no published data for that
  area yet. Councils are still adding their traffic orders. No line never means
  parking is unrestricted.
- *A line is grey or dotted.* The app has data for that kerb but cannot interpret it
  reliably, so it does not guess. Check the sign.
- *The app says I can park but the sign says otherwise.* Follow the sign. Published
  data can be incomplete, out of date or wrong, and temporary restrictions may not
  be included. Please tell us the street and what the sign says so we can look into it.
- *A line is amber.* Parking there depends on something the app cannot confirm, such
  as a permit.
- *The price is missing.* Many councils do not publish tariffs in a form the app can
  read. Check the sign or the payment app.
- *My location does not show.* Allow location access in Settings › Privacy &
  Security › Location Services › Locis.

**Deleting data:** Locis stores your settings and saved parking data only on your
device. Deleting the app removes them. There is no account to delete.

**Response time:** use the same wording as the other apps' support pages.

**Important notice (add as a short closing section on the support page and the app
page):**
Parking information is provided as guidance. Always check local signs, road markings
and temporary restrictions before parking. Curated Design cannot accept
responsibility for penalty charges.

## When done

Tell me the final URLs so they can be entered in the app's configuration and in
App Store Connect:

- Privacy policy URL: `https://curateddesign.studio/apps/locis/privacy/`
- Support URL: `https://curateddesign.studio/apps/locis/support/`
- Marketing URL: `https://curateddesign.studio/apps/locis/`
