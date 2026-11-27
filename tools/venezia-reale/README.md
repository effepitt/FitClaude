# Venezia reale dalla Carta Tecnica

Genera il modello 3D del percorso **San Nicolò dei Mendicoli → Fondamenta Barbarigo → San Sebastiano →
Zattere → Punta della Dogana → Salute → Guggenheim → Accademia** (circa 3,2 km) dai dati DBGT del Comune
di Venezia (sistema EPSG:3004).

```
pip3 install shapely trimesh mapbox_earcut scipy scikit-image pyshp networkx
DBGT_DIR=~/VeniceRebuild/modern-data/carta-tecnica/DBGT_shp python3 build.py out
```

Uscita in `out/`:
- `venezia_sannicolo_accademia.glb`: metri, Y in alto, origine locale (X0, Y0 in EPSG:3004 in `route.json`).
  Mesh separate per materiale: `Facciata_0..8` (tinte d'intonaco in `palette.json`), `Edifici_Tetti`,
  `Suolo_Masegni`, `Rive_PietraIstria`, `Acqua`, `Ponti`. UV in metri (1 unità = 1 m) per texture ripetibili.
- `route.json`: percorso pedonale campionato ogni metro (x est, y nord, z quota) e i nizioleti veri
  (nome della calle/fondamenta/ponte con l'indice del punto in cui si entra).

Gli edifici sono estrusi dalle unità volumetriche `UN_VOL` tra la quota di base `UN_VOL_QB` e la gronda
`UN_VOL_QG`; i ponti sono incurvati ad arco lungo l'asse che attraversa il rio; il percorso è calcolato
come cammino minimo sulla superficie percorribile (rive, campi, calli e ponti), lontano dai muri.
