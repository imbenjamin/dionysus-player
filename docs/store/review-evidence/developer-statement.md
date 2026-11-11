# Statement from the developer of Dionysus Player

<!--
The text Benjamin signs and exports to `developer-statement.pdf` for App
Review Information's attachments (guideline 5.2.3, 2026-11-09). In the signed
copy, `<review server URL>` is replaced with the real address; that PDF is
not committed, since the address is kept out of this repo. Update the film
list here whenever `../review-server.md` changes.
-->

**App:** Dionysus Player, for iPhone, iPad and Apple TV
**Developer:** Benjamin Hill

I am the developer of Dionysus Player and I make this statement in answer to
App Review's request, under guideline 5.2.3, for documentary evidence of
rights to third-party audio or video streaming, catalogues and discovery
services.

## What the app is

1. Dionysus Player is a client for Jellyfin, a free, open-source media server
   published under the GNU General Public License, version 2 (attached:
   `jellyfin-license.pdf`). People install Jellyfin on their own hardware and
   fill it with their own media. Its REST API is publicly documented for any
   client to use at https://api.jellyfin.org (attached: `jellyfin-api.pdf`).
2. The app ships with no server address, no content, no catalogue and no
   account. On first launch the user enters the address of their own Jellyfin
   server and signs in with an account that the server's administrator made.
3. Every network request goes to that one address. The only other traffic is
   an optional scan of the user's local network for Jellyfin servers, which
   stays on that network. The app contacts no content provider, no metadata,
   artwork or ratings service, no catalogue or discovery service and no
   analytics service. Titles, descriptions and artwork are served by the
   user's own server.
4. The app cannot find, buy, rent or otherwise acquire content. It plays only
   what the person running the server has already put there.

## The review server

5. For App Review I operate a Jellyfin server of my own, at
   `<review server URL>`. It runs on my own hardware, I administer it, and the
   review account `reviewer` can play and download but cannot change or delete
   anything.
6. Its library holds only these films, each released by the Blender Foundation
   under a Creative Commons Attribution licence. Each file was downloaded from
   the Blender Foundation (`download.blender.org` or `video.blender.org`), and
   the licence for each is attached, captured from an official Blender page.
   No title, description or image comes from any online catalogue: they come
   from the Blender Foundation's own releases, and each description ends with
   the film's attribution.

| Film | Licence | Attached evidence |
|---|---|---|
| Big Buck Bunny (2008) | CC BY 3.0 | `big-buck-bunny-license.pdf` |
| Sintel (2010) | CC BY 3.0 | `sintel-license.pdf` |
| Tears of Steel (2012) | CC BY 3.0; soundtrack CC BY-ND 3.0 | `tears-of-steel-license.pdf`, `tears-of-steel-soundtrack-license.pdf` |
| Cosmos Laundromat: First Cycle (2015) | CC BY 3.0 | `cosmos-laundromat-license.pdf` |
| Spring (2019) | CC BY 4.0 | `spring-license.pdf` |
| Sprite Fright (2021) | CC BY | `sprite-fright-license.pdf` |
| Charge (2022) | CC BY 4.0 | `charge-wikimedia-commons.pdf`, `charge-project-page.pdf`, `blender-studio-terms.pdf` |
| Caminandes 2: Gran Dillama (2013) | CC BY 4.0 | `caminandes-2-project-page.pdf`, `blender-studio-terms.pdf` |
| Caminandes 3: Llamigos (2016) | CC BY | `caminandes-3-video-blender-org.pdf`, `caminandes-3-project-page.pdf`, `blender-studio-terms.pdf` |

7. Blender Studio's terms (`blender-studio-terms.pdf`) state that, unless
   noted otherwise, its digital content is available under Creative Commons
   Attribution 4.0. It is the evidence for the two films whose own pages give
   no licence (Charge and Caminandes 2) and for the artwork. No Blender logo or
   other trademark is used as artwork.

I confirm that the above is true to the best of my knowledge.

Signed: ______________________________

Name: Benjamin Hill

Date: ______________________________
