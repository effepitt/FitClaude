"""Costruisce la Venezia reale (percorso San Nicolò dei Mendicoli - Zattere - Salute - Accademia) dalla Carta Tecnica DBGT.
Uscita: un .glb (metri, Y in alto, origine locale) con mesh separate per materiale, il percorso pedonale
(route.json) e i nizioleti lungo il percorso.
"""
import json, math, sys
import numpy as np
import shapely
from shapely.geometry import box, Polygon, MultiPolygon, LineString, Point
from shapely.ops import unary_union
from scipy import ndimage
from skimage.graph import route_through_array
import trimesh
from shp import load_shp

OUT = sys.argv[1] if len(sys.argv) > 1 else 'out'
X0, Y0, X1, Y1 = 2309900.0, 5033500.0, 2312000.0, 5034900.0
load=lambda _p,t: load_shp(t,(X0,Y0,X1,Y1))
WATER_Z = 0.0        # livello medio del mare, quota di riferimento
GROUND_Z = 1.3       # piano di calpestio medio (masegni)
RES = 0.5            # griglia per il calcolo del percorso (m)
rng = np.random.default_rng(7)

def polys(g):
    if g.is_empty: return []
    if isinstance(g, Polygon): return [g]
    if hasattr(g, 'geoms'): return [p for x in g.geoms for p in polys(x)]
    return []

def L(x, y):  # coordinate locali
    return x - X0, y - Y0

# ---------------------------------------------------------------- dati
area = box(X0, Y0, X1, Y1)
vols = load(None, 'un_vol')
water = unary_union([r['geom'] for r in load(None, 'can_lag')] + [r['geom'] for r in load(None, 'sp_acq')]).intersection(area)
bridges = [r['geom'].buffer(0) for r in load(None, 'ponte')]
bridge_u = unary_union(bridges)
names = load(None, 'tp_str')
quotes = load(None, 'pt_quo')
qz = np.median([r['PT_QUO_Q'] for r in quotes if r['PT_QUO_Q'] and 0.5 < r['PT_QUO_Q'] < 4])
GROUND_Z = float(qz)
WATER_Z = GROUND_Z - 1.45  # acqua ~1,1 m sotto le fondamenta
print("quota media del suolo", GROUND_Z)

build_u = unary_union([r['geom'].buffer(0) for r in vols])
land = area.difference(water).buffer(0)

# ---------------------------------------------------------------- mesh helpers
class Mesh:
    def __init__(s): s.v=[]; s.uv=[]; s.f=[]; s.c=[]
    def add(s, verts, uvs, faces, color=(1,1,1,1)):
        b=len(s.v); s.v+=verts; s.uv+=uvs; s.f+=[[a+b for a in t] for t in faces]; s.c+=[color]*len(verts)
    def trimesh(s):
        v=np.array(s.v,float)
        # da (x est, y nord, z alto) a glTF (x, y alto, z sud)
        v=np.c_[v[:,0], v[:,2], -v[:,1]]
        m=trimesh.Trimesh(v, np.array(s.f), process=False,
            visual=trimesh.visual.TextureVisuals(uv=np.array(s.uv,float)))
        _ = m.vertex_normals
        return m

def triangulate(poly, z, uvscale=1.0):
    v2, f = trimesh.creation.triangulate_polygon(poly, engine='earcut')
    verts=[(L(x,y)[0], L(x,y)[1], z) for x,y in v2]
    uvs=[(vx/uvscale, vy/uvscale) for vx,vy,_ in verts]
    return verts, uvs, f.tolist()

def walls(poly, z0, z1, mesh, color, outward=True):
    for ring in [poly.exterior] + list(poly.interiors):
        pts=list(ring.coords)
        ccw = ring.is_ccw
        u=0.0
        for (ax,ay),(bx,by) in zip(pts[:-1], pts[1:]):
            ax,ay=L(ax,ay); bx,by=L(bx,by)
            d=math.hypot(bx-ax,by-ay)
            if d<1e-3: continue
            verts=[(ax,ay,z0),(bx,by,z0),(bx,by,z1),(ax,ay,z1)]
            uvs=[(u,z0),(u+d,z0),(u+d,z1),(u,z1)]
            # esterno CCW -> normali verso fuori con questo ordine; i fori al contrario
            faces=[[0,1,2],[0,2,3]] if ccw==(ring is poly.exterior) else [[0,2,1],[0,3,2]]
            if ring is not poly.exterior: faces=[[0,1,2],[0,2,3]] if not ccw else [[0,2,1],[0,3,2]]
            mesh.add(verts,uvs,faces,color); u+=d

# palette intonaci veneziani (tinta moltiplicata sulla texture)
PALETTE=[(0.93,0.78,0.62),(0.86,0.55,0.42),(0.95,0.87,0.72),(0.80,0.45,0.35),(0.92,0.70,0.48),
         (0.88,0.82,0.74),(0.74,0.40,0.32),(0.96,0.90,0.80),(0.85,0.63,0.50)]

facades=[Mesh() for _ in PALETTE]
roofs_m, ground_m, quay_m, water_m, bridge_m = Mesh(),Mesh(),Mesh(),Mesh(),Mesh()

# ---------------------------------------------------------------- edifici
nb=0
for r in vols:
    qb=r['UN_VOL_QB'] or GROUND_Z; qg=r['UN_VOL_QG'] or r['UN_VOL_QE']
    if not qg or qg<=qb+0.5: continue
    if qg-qb>80: continue
    ci=int(rng.integers(len(PALETTE))); col=PALETTE[ci]+(1.0,); walls_m=facades[ci]
    for p in polys(r['geom'].buffer(0)):
        p=shapely.geometry.polygon.orient(p.simplify(0.05),1.0)
        if p.area<1: continue
        walls(p, min(qb,GROUND_Z), qg, walls_m, col)
        try:
            v,uv,f=triangulate(p, qg, 1.0); roofs_m.add(v,uv,f)
        except Exception: pass
        nb+=1
print('volumi estrusi', nb)

# ---------------------------------------------------------------- suolo, rive, acqua
open_land = land.difference(build_u.buffer(-0.05)).buffer(0)
for p in polys(open_land):
    p=shapely.geometry.polygon.orient(p.simplify(0.05),1.0)
    if p.area<0.5: continue
    try:
        v,uv,f=triangulate(p, GROUND_Z, 1.0); ground_m.add(v,uv,f)
    except Exception: pass
# rive in pietra d'Istria: pareti della terraferma verso l'acqua
for p in polys(land):
    p=shapely.geometry.polygon.orient(p.simplify(0.05),1.0)
    walls(p, WATER_Z-1.5, GROUND_Z, quay_m, (1,1,1,1))
for p in polys(water.buffer(2.0).intersection(area)):
    p=shapely.geometry.polygon.orient(p,1.0)
    try:
        v,uv,f=triangulate(p, WATER_Z+0.35, 4.0); water_m.add(v,uv,f)
    except Exception: pass

# ---------------------------------------------------------------- ponti ad arco
bridge_info=[]
for g in bridges:
    for p in polys(g):
        if p.area<4: continue
        rect=p.minimum_rotated_rectangle
        cs=list(rect.exterior.coords)
        e=[(cs[i],cs[i+1]) for i in range(4)]
        lens=[math.dist(a,b) for a,b in e]
        # asse del ponte = lato che attraversa l'acqua: quello la cui retta interseca di piu' l'acqua
        ctr=np.array(rect.centroid.coords[0])
        best=None
        for i in (0,1):
            a,b=e[i]; d=np.array(b)-np.array(a); sp=np.linalg.norm(d); d=d/sp
            ends=[Point(*(ctr+k*d*(sp/2+1.5))) for k in (-1,1)]
            score=sum(land.contains(q) for q in ends)+0.01*sp
            if best is None or score>best[0]: best=(score,i)
        a,b=e[best[1]]
        ax=np.array(b)-np.array(a); span=np.linalg.norm(ax); ax/=span
        origin=ctr-ax*span/2
        rise=min(2.2, 0.35+0.12*span) if span<45 else 0.0
        bridge_info.append({'poly':p,'origin':origin,'axis':ax,'span':span,'rise':rise})
        dense=shapely.segmentize(shapely.geometry.polygon.orient(p,1.0),1.0)
        v2,f=trimesh.creation.triangulate_polygon(dense, engine='earcut')
        # suddivisione per curvare bene l'impalcato
        tm=trimesh.Trimesh(np.c_[v2,np.zeros(len(v2))],f,process=False)
        tm=tm.subdivide_to_size(2.0 if span<45 else 50.0, max_iter=4)
        def zf(x,y):
            t=np.clip(np.dot(np.array([x,y])-origin,ax)/span,0,1)
            return GROUND_Z+rise*math.sin(math.pi*t)
        verts=[(L(x,y)[0],L(x,y)[1],zf(x,y)) for x,y,_ in tm.vertices]
        bridge_m.add(verts,[(vx,vy) for vx,vy,_ in verts],tm.faces.tolist())
        # spallette (parapetti) lungo il bordo
        ring=list(dense.exterior.coords)
        for (x1,y1),(x2,y2) in zip(ring[:-1],ring[1:]):
            z1,z2=zf(x1,y1),zf(x2,y2)
            a1,b1=L(x1,y1); a2,b2=L(x2,y2)
            d=math.hypot(a2-a1,b2-b1)
            if d<1e-3 or abs(((x2-x1)*ax[0]+(y2-y1)*ax[1])/d)<0.6: continue
            verts=[(a1,b1,z1-0.3),(a2,b2,z2-0.3),(a2,b2,z2+0.9),(a1,b1,z1+0.9)]
            bridge_m.add(verts,[(0,0),(d,0),(d,1.2),(0,1.2)],[[0,1,2],[0,2,3],[0,2,1],[0,3,2]])
print('ponti', len(bridge_info))

# ---------------------------------------------------------------- percorso pedonale
W=int((X1-X0)/RES); H=int((Y1-Y0)/RES)
xs=X0+(np.arange(W)+0.5)*RES; ys=Y0+(np.arange(H)+0.5)*RES
XX,YY=np.meshgrid(xs,ys)
big_u=unary_union([r['geom'].buffer(0) for r in vols if r['geom'].area>25 and (r['UN_VOL_QG'] or 0)-(r['UN_VOL_QB'] or 0)>3])
walk_geom=unary_union([land.difference(big_u.buffer(-0.05)), bridge_u]).buffer(0)
shapely.prepare(walk_geom)
walk=shapely.contains_xy(walk_geom, XX, YY)
# niente acqua salvo i ponti
dist=ndimage.distance_transform_edt(walk)*RES
cost=np.where(walk, 1.0+3.0/np.maximum(dist,0.5), 1e6)
WAY=[("Chiesa di San Nicolò dei Mendicoli",2310038,5034531),
     ("Fondamenta Barbarigo",2310216,5034529),
     ("Fondamenta de San Sebastian",2310390,5034504),
     ("Zattere al Ponte Longo",2310619,5034255),
     ("Zattere ai Gesuati",2310913,5034139),
     ("Zattere al Spirito Santo",2311200,5034040),
     ("Zattere al Spirito Santo (est)",2311470,5034095),
     ("Zattere ai Saloni",2311592,5034217),
     ("Punta della Dogana",2311696,5034294),
     ("Basilica della Salute",2311553,5034298),
     ("Campo San Gregorio",2311429,5034272),
     ("Collezione Peggy Guggenheim",2311246,5034247),
     ("Campo San Vio",2311165,5034293),
     ("Gallerie dell'Accademia",2311029,5034380)]
def cell(x,y):
    j=int((x-X0)/RES); i=int((y-Y0)/RES)
    # aggancia alla cella percorribile piu' vicina
    if not walk[i,j]:
        ii,jj=np.nonzero(walk[max(0,i-30):i+30,max(0,j-30):j+30])
        k=np.argmin((ii-30)**2+(jj-30)**2); i,j=max(0,i-30)+ii[k],max(0,j-30)+jj[k]
    return i,j
path=[]
for (n1,x1,y1),(n2,x2,y2) in zip(WAY[:-1],WAY[1:]):
    p,c=route_through_array(cost,cell(x1,y1),cell(x2,y2),fully_connected=True,geometric=True)
    path+=p if not path else p[1:]
pts=[(X0+(j+0.5)*RES, Y0+(i+0.5)*RES) for i,j in path]
line=LineString(pts).simplify(0.6)
# lisciatura (Chaikin) e ricampionamento ogni metro
c=np.array(line.coords)
for _ in range(3):
    q=0.75*c[:-1]+0.25*c[1:]; r_=0.25*c[:-1]+0.75*c[1:]
    c=np.vstack([c[:1],np.column_stack([q,r_]).reshape(-1,2),c[-1:]])
line=LineString(c)
n=int(line.length)
samples=[line.interpolate(d) for d in np.linspace(0,line.length,n+1)]
def zpath(x,y):
    for b in bridge_info:
        if b['poly'].buffer(0.3).contains(Point(x,y)):
            t=np.clip(np.dot(np.array([x,y])-b['origin'],b['axis'])/b['span'],0,1)
            return GROUND_Z+b['rise']*math.sin(math.pi*t)
    return GROUND_Z
route=[]
for s in samples:
    lx,ly=L(s.x,s.y); route.append([round(lx,2),round(ly,2),round(zpath(s.x,s.y)+0.0,2)])
# lisciatura della quota (scalini dei ponti -> rampa morbida)
z=np.array([r[2] for r in route]); z=ndimage.gaussian_filter1d(z,1.5)
for r,zz in zip(route,z): r[2]=round(float(zz),2)
print('percorso', round(line.length), 'm')

# nizioleti: nome della calle/fondamenta/campo attraversato, al punto d'ingresso
signs=[]; last=None
named=[(r['TP_STR_NOM'],r['geom'].buffer(0)) for r in names]
for k,s in enumerate(samples):
    here=None
    for nm,g in named:
        if g.contains(s): here=nm; break
    if here and here!=last:
        signs.append({'name':here,'route_index':k,'pos':route[k]}); last=here
    elif here: last=here
print('nizioleti', len(signs))

# ---------------------------------------------------------------- esportazione
scene=trimesh.Scene()
for name,m in [(f'Facciata_{i}',m) for i,m in enumerate(facades)]+[('Edifici_Tetti',roofs_m),('Suolo_Masegni',ground_m),
               ('Rive_PietraIstria',quay_m),('Acqua',water_m),('Ponti',bridge_m)]:
    if m.v: scene.add_geometry(m.trimesh(), node_name=name, geom_name=name)
import os; os.makedirs(OUT,exist_ok=True)
scene.export(f'{OUT}/venezia_sannicolo_accademia.glb')
json.dump({'crs':'EPSG:3004','origin':[X0,Y0],'units':'m','axes':'x=est, y=nord, z=quota s.l.m. (nel glb: Y in alto, -Z = nord)',
           'ground_z':GROUND_Z,'length_m':round(line.length,1),'waypoints':[w[0] for w in WAY],
           'route':route,'signs':signs}, open(f'{OUT}/route.json','w'), ensure_ascii=False)
json.dump({f'Facciata_{i}':c for i,c in enumerate(PALETTE)},open(f'{OUT}/palette.json','w'))
print('ok', {k:len(m.v) for k,m in [('roofs',roofs_m),('ground',ground_m),('quay',quay_m),('water',water_m),('bridge',bridge_m)]})
