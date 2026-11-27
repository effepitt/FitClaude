import shapefile, shapely.geometry as sg
from shapely.geometry import box
import os
B=os.path.expanduser(os.environ.get('DBGT_DIR','~/VeniceRebuild/modern-data/carta-tecnica/DBGT_shp'))+'/'
PATHS={'un_vol':'Strato02_Immobili_Antropizzazioni/Tema0201_Edificato/UN_VOL','ponte':'Strato02_Immobili_Antropizzazioni/Tema0203_OpereInfrastruttureTrasporto/PONTE',
'can_lag':'Strato04_Idrografia/Tema0404_ReticoloIdrografico/CAN_LAG','sp_acq':'Strato04_Idrografia/Tema0401_AcqueInterne_Transizione/SP_ACQ',
'tp_str':'Strato03_GestioneViabilita_Indirizzi/Tema0301_ToponimiNumeriCivici/TP_STR','pt_quo':'Strato05_Orografia/Tema0501_Altimetria/PT_QUO'}
def load_shp(table, bbox):
    r=shapefile.Reader(B+PATHS[table], encoding='latin1'); out=[]
    x0,y0,x1,y1=bbox; clip=box(*bbox)
    for i,sh in enumerate(r.iterShapes()):
        if sh.shapeType==0: continue
        bb=sh.bbox if hasattr(sh,'bbox') else None
        if bb and (bb[2]<x0 or bb[0]>x1 or bb[3]<y0 or bb[1]>y1): continue
        g=sg.shape(sh.__geo_interface__)
        d=r.record(i).as_dict(); d['geom']=g; out.append(d)
    return out
