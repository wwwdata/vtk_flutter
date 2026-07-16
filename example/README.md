# vtk_flutter renderer lab

This application is the executable feature proof for `vtk_flutter`. It creates
a deterministic synthetic signed-int16 volume and exercises:

- oblique MPR, 3D volume, and high-visibility locator rendering;
- window/level and camera controls;
- viewport resize and volume replacement;
- presentation-resource recreation;
- session disposal and recreation.

It has no backend, patient data, or application-specific dependency.

## Run

After the pinned native release exists:

```sh
fvm flutter pub get
fvm flutter run -d macos
```

Substitute an Android, iOS, Windows, or Chrome device as appropriate. Native
maintainers testing before a release can point the build hook at a local
library as described in the repository README.
