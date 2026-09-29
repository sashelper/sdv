# Releasing sdv

## One-time setup

1. **Create the GitHub repository** (public) and push:

   ```sh
   git add -A && git commit -m "sdv 0.1.0"
   gh repo create sashelper/sdv --public --source . --push \
     --description "Open R objects in StatDataViewer from RStudio"
   ```

   Pushing to `main` runs `.github/workflows/R-CMD-check.yaml`, which runs
   R CMD check on macOS, Windows and Linux.

2. **Set up r-universe** so users get prebuilt macOS/Windows binaries:

   - Create the repository `sashelper/sashelper.r-universe.dev`. It holds a
     single file, `packages.json`:

     ```json
     [
       {
         "package": "sdv",
         "url": "https://github.com/sashelper/sdv"
       }
     ]
     ```

   - Install the r-universe GitHub app on the `sashelper` account:
     <https://github.com/apps/r-universe/installations/new>.
   - Wait for the first build (about an hour) at
     <https://sashelper.r-universe.dev>. From then on, every push to
     `sashelper/sdv` is rebuilt automatically.

3. **Link to it from StatDataViewer**: put the install command on the website
   and in the app's Help menu:

   ```r
   install.packages("sdv", repos = c("https://sashelper.r-universe.dev",
                                     "https://cloud.r-project.org"))
   ```

## Each release

1. Update `Version:` in `DESCRIPTION` and add a section to `NEWS.md`.
2. Check the package:

   ```sh
   Rscript -e 'roxygen2::roxygenise()'
   R CMD build . && R CMD check --as-cran sdv_*.tar.gz
   Rscript -e 'testthat::test_local()'   # set SDV_SOURCE_DIR to also run the librdata compatibility test
   ```

3. If the change touches launching the app, test by hand on Windows too. CI
   runs the unit tests there, but it cannot start StatDataViewer.
4. Commit, tag and push:

   ```sh
   git commit -am "sdv x.y.z"
   git tag vx.y.z && git push && git push --tags
   gh release create vx.y.z --notes-from-tag
   ```

   r-universe picks up the new version automatically.

## CRAN (optional, later)

`R CMD check --as-cran` shows only the expected new-submission NOTE and a NOTE
for `unlockBinding` in `R/viewer_override.R`. The `unlockBinding` NOTE is the
likely obstacle. `sdv_use_as_viewer()` replaces `View` in the attached
`package:utils` environment (RStudio replaces `View` the same way), and CRAN
reviewers usually ask packages not to modify other packages. Before
submitting, either justify this in `cran-comments.md` or leave View()
takeover out of the CRAN version. Submit with `devtools::submit_cran()`.
