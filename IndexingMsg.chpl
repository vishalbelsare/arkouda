module IndexingMsg
{
    use ServerConfig;
    use MultiTypeSymEntry;
    use MultiTypeSymbolTable;

    // intIndex "a[int]" response to __getitem__(int)
    proc intIndexMsg(req_msg: string, st: borrowed SymTab):string {
        var pn = "intIndex";
        var rep_msg: string; // response message
        var fields = req_msg.split(); // split request into fields
        var cmd = fields[1];
        var name = fields[2];
        var idx = try! fields[3]:int;
        if v {try! writeln("%s %s %i".format(cmd, name, idx));try! stdout.flush();}

         var gEnt: borrowed GenSymEntry = st.lookup(name);
         if (gEnt == nil) {return unknownSymbolError(pn,name);}
         
         select (gEnt.dtype) {
             when (DType.Int64) {
                 var e = toSymEntry(gEnt, int);
                 return try! "item %s %t".format(dtype2str(e.dtype),e.a[idx]);
             }
             when (DType.Float64) {
                 var e = toSymEntry(gEnt,real);
                 return try! "item %s %.17r".format(dtype2str(e.dtype),e.a[idx]);
             }
             when (DType.Bool) {
                 var e = toSymEntry(gEnt,bool);
                 var s = try! "item %s %t".format(dtype2str(e.dtype),e.a[idx]);
                 s = s.replace("true","True"); // chapel to python bool
                 s = s.replace("false","False"); // chapel to python bool
                 return s;
             }
             otherwise {return notImplementedError(pn,dtype2str(gEnt.dtype));}
         }
    }

    // sliceIndex "a[slice]" response to __getitem__(slice)
    proc sliceIndexMsg(req_msg: string, st: borrowed SymTab): string {
        var pn = "sliceIndex";
        var rep_msg: string; // response message
        var fields = req_msg.split(); // split request into fields
        var cmd = fields[1];
        var name = fields[2];
        var start = try! fields[3]:int;
        var stop = try! fields[4]:int;
        var stride = try! fields[5]:int;
        var slice: range(stridable=true);

        // convert python slice to chapel slice
        // backwards iteration with negative stride
        if  (start > stop) & (stride < 0) {slice = (stop+1)..start by stride;}
        // forward iteration with positive stride
        else if (start <= stop) & (stride > 0) {slice = start..(stop-1) by stride;}
        // BAD FORM start < stop and stride is negative
        else {slice = 1..0;}

        // get next symbol name
        var rname = st.next_name();

        if v {try! writeln("%s %s %i %i %i : %t , %s".format(cmd, name, start, stop, stride, slice, rname));try! stdout.flush();}

        var gEnt: borrowed GenSymEntry = st.lookup(name);
        if (gEnt == nil) {return unknownSymbolError(pn,name);}

        select(gEnt.dtype) {
            when (DType.Int64) {
                var e = toSymEntry(gEnt,int);
                var aD = makeDistDom(slice.size);
                var a = makeDistArray(slice.size, int);
                [(i,j) in zip(0..#slice.size, slice)] a[i] = e.a[j];
                st.addEntry(rname, new shared SymEntry(a));
            }
            when (DType.Float64) {
                var e = toSymEntry(gEnt,real);
                var aD = makeDistDom(slice.size);
                var a = makeDistArray(slice.size, real);
                [(i,j) in zip(0..#slice.size, slice)] a[i] = e.a[j];                
                st.addEntry(rname, new shared SymEntry(a));                
            }
            when (DType.Bool) {
                var e = toSymEntry(gEnt,bool);
                var aD = makeDistDom(slice.size);
                var a = makeDistArray(slice.size, bool);
                [(i,j) in zip(0..#slice.size, slice)] a[i] = e.a[j];                
                st.addEntry(rname, new shared SymEntry(a));                
            }
            otherwise {return notImplementedError(pn,dtype2str(gEnt.dtype));}
        }
        return try! "created " + st.attrib(rname);
    }

    // pdarrayIndex "a[pdarray]" response to __getitem__(pdarray)
    proc pdarrayIndexMsg(req_msg: string, st: borrowed SymTab): string {
        var pn = "pdarrayIndex";
        var rep_msg: string; // response message
        var fields = req_msg.split(); // split request into fields
        var cmd = fields[1];
        var name = fields[2];
        var iname = fields[3];

        // get next symbol name
        var rname = st.next_name();

        if v {try! writeln("%s %s %s : %s".format(cmd, name, iname, rname));try! stdout.flush();}

        var gX: borrowed GenSymEntry = st.lookup(name);
        if (gX == nil) {return unknownSymbolError(pn,name);}
        var gIV: borrowed GenSymEntry = st.lookup(iname);
        if (gIV == nil) {return unknownSymbolError(pn,iname);}

        // add check for IV to be dtype int64 or bool
        
        select(gX.dtype, gIV.dtype) {
            when (DType.Int64, DType.Int64) {
                var e = toSymEntry(gX,int);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                var a: [iv.aD] int;
                [i in iv.aD] a[i] = e.a[iv.a[i]]; // bounds check iv[i] against e.aD?
                st.addEntry(rname, new shared SymEntry(a));
            }
            when (DType.Int64, DType.Bool) {
                var e = toSymEntry(gX,int);
                var truth = toSymEntry(gIV,bool);
                var iv: [truth.aD] int = (+ scan truth.a);
                var pop = iv[iv.size-1];
                if v {writeln("pop = ",pop,"last-scan = ",iv[iv.size-1]);try! stdout.flush();}
                var a = makeDistArray(pop, int);
                [i in e.aD] if (truth.a[i] == true) {a[iv[i]-1] = e.a[i];}// iv[i]-1 for zero base index
                st.addEntry(rname, new shared SymEntry(a));
            }
            when (DType.Float64, DType.Int64) {
                var e = toSymEntry(gX,real);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                var a: [iv.aD] real;
                [i in iv.aD] a[i] = e.a[iv.a[i]]; // bounds check iv[i] against e.aD?
                st.addEntry(rname, new shared SymEntry(a));                
            }
            when (DType.Float64, DType.Bool) {
                var e = toSymEntry(gX,real);
                var truth = toSymEntry(gIV,bool);
                var iv: [truth.aD] int = (+ scan truth.a);
                var pop = iv[iv.size-1];
                if v {writeln("pop = ",pop,"last-scan = ",iv[iv.size-1]);try! stdout.flush();}
                var a = makeDistArray(pop, real);
                [i in e.aD] if (truth.a[i] == true) {a[iv[i]-1] = e.a[i];}// iv[i]-1 for zero base index
                st.addEntry(rname, new shared SymEntry(a));
            }
            when (DType.Bool, DType.Int64) {
                var e = toSymEntry(gX,bool);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                var a: [iv.aD] bool;
                [i in iv.aD] a[i] = e.a[iv.a[i]];// bounds check iv[i] against e.aD?
                st.addEntry(rname, new shared SymEntry(a));                
            }
            when (DType.Bool, DType.Bool) {
                var e = toSymEntry(gX,bool);
                var truth = toSymEntry(gIV,bool);
                var iv: [truth.aD] int = (+ scan truth.a);
                var pop = iv[iv.size-1];
                if v {writeln("pop = ",pop,"last-scan = ",iv[iv.size-1]);try! stdout.flush();}
                var a = makeDistArray(pop, bool);
                [i in e.aD] if (truth.a[i] == true) {a[iv[i]-1] = e.a[i];}// iv[i]-1 for zero base index
                st.addEntry(rname, new shared SymEntry(a));
            }
            otherwise {return notImplementedError(pn,
                                                  "("+dtype2str(gX.dtype)+","+dtype2str(gIV.dtype)+")");}
        }
        return try! "created " + st.attrib(rname);
    }

    // setIntIndexToValue "a[int] = value" response to __setitem__(int, value)
    proc setIntIndexToValueMsg(req_msg: string, st: borrowed SymTab):string {
        var pn = "setIntIndexToValue";
        var rep_msg: string; // response message
        var fields = req_msg.split(); // split request into fields
        var cmd = fields[1];
        var name = fields[2];
        var idx = try! fields[3]:int;
        var dtype = str2dtype(fields[4]);
        var value = fields[5];
        if v {try! writeln("%s %s %i".format(cmd, name, idx));try! stdout.flush();}

         var gEnt: borrowed GenSymEntry = st.lookup(name);
         if (gEnt == nil) {return unknownSymbolError(pn,name);}

         select (gEnt.dtype, dtype) {
             when (DType.Int64, DType.Int64) {
                 var e = toSymEntry(gEnt,int);
                 var val = try! value:int;
                 e.a[idx] = val;
             }
             when (DType.Int64, DType.Float64) {
                 var e = toSymEntry(gEnt,int);
                 var val = try! value:real;
                 e.a[idx] = val:int;
             }
             when (DType.Int64, DType.Bool) {
                 var e = toSymEntry(gEnt,int);
                 value = value.replace("True","true");// chapel to python bool
                 value = value.replace("False","false");// chapel to python bool
                 var val = try! value:bool;
                 e.a[idx] = val:int;
             }
             when (DType.Float64, DType.Int64) {
                 var e = toSymEntry(gEnt,real);
                 var val = try! value:int;
                 e.a[idx] = val;
             }
             when (DType.Float64, DType.Float64) {
                 var e = toSymEntry(gEnt,real);
                 var val = try! value:real;
                 e.a[idx] = val;
             }
             when (DType.Float64, DType.Bool) {
                 var e = toSymEntry(gEnt,real);
                 value = value.replace("True","true");// chapel to python bool
                 value = value.replace("False","false");// chapel to python bool
                 var b = try! value:bool;
                 var val:real;
                 if b {val = 1.0;} else {val = 0.0;}
                 e.a[idx] = val;
             }
             when (DType.Bool, DType.Int64) {
                 var e = toSymEntry(gEnt,bool);
                 var val = try! value:int;
                 e.a[idx] = val:bool;
             }
             when (DType.Bool, DType.Float64) {
                 var e = toSymEntry(gEnt,bool);
                 var val = try! value:real;
                 e.a[idx] = val:bool;
             }
             when (DType.Bool, DType.Bool) {
                 var e = toSymEntry(gEnt,bool);
                 value = value.replace("True","true");// chapel to python bool
                 value = value.replace("False","false");// chapel to python bool
                 var val = try! value:bool;
                 e.a[idx] = val;
             }
             otherwise {return notImplementedError(pn,
                                                   "("+dtype2str(gEnt.dtype)+","+dtype2str(dtype)+")");}
         }
         return try! "%s success".format(pn);
    }


    // setPdarrayIndexToValue "a[pdarray] = value" response to __setitem__(pdarray, value)
    proc setPdarrayIndexToValueMsg(req_msg: string, st: borrowed SymTab):string {
        var pn = "setPdarrayIndexToValue";
        var rep_msg: string; // response message
        var fields = req_msg.split(); // split request into fields
        var cmd = fields[1];
        var name = fields[2];
        var iname = fields[3];
        var dtype = str2dtype(fields[4]);
        var value = fields[5];

        var gX: borrowed GenSymEntry = st.lookup(name);
        if (gX == nil) {return unknownSymbolError(pn,name);}
        var gIV: borrowed GenSymEntry = st.lookup(iname);
        if (gIV == nil) {return unknownSymbolError(pn,iname);}

        // add check for IV to be dtype of int64 or bool
        
        select(gX.dtype, gIV.dtype, dtype) {
            when (DType.Int64, DType.Int64, DType.Int64) {
                var e = toSymEntry(gX,int);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                var val = try! value:int;
                [i in iv.a] e.a[i] = val;
            }
            when (DType.Float64, DType.Int64, DType.Float64) {
                var e = toSymEntry(gX,real);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                var val = try! value:real;
                [i in iv.a] e.a[i] = val;
            }
            when (DType.Bool, DType.Int64, DType.Bool) {
                var e = toSymEntry(gX,bool);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                value = value.replace("True","true");// chapel to python bool
                value = value.replace("False","false");// chapel to python bool
                var val = try! value:bool;
                [i in iv.a] e.a[i] = val;
            }
            otherwise {return notImplementedError(pn,
                                                  "("+dtype2str(gX.dtype)+","+dtype2str(gIV.dtype)+","+dtype2str(dtype)+")");}
        }
        return try! "%s success".format(pn);
    }

    // setPdarrayIndexToPdarray "a[pdarray] = pdarray" response to __setitem__(pdarray, pdarray)
    proc setPdarrayIndexToPdarrayMsg(req_msg: string, st: borrowed SymTab):string {
        var pn = "setPdarrayIndexToPdarray";
        var rep_msg: string; // response message
        var fields = req_msg.split(); // split request into fields
        var cmd = fields[1];
        var name = fields[2];
        var iname = fields[3];
        var yname = fields[4];

        // get next symbol name
        var rname = st.next_name();

        var gX: borrowed GenSymEntry = st.lookup(name);
        if (gX == nil) {return unknownSymbolError(pn,name);}
        var gIV: borrowed GenSymEntry = st.lookup(iname);
        if (gIV == nil) {return unknownSymbolError(pn,iname);}
        var gY: borrowed GenSymEntry = st.lookup(yname);
        if (gY == nil) {return unknownSymbolError(pn,yname);}

        // add check to make syre IV and Y are same size
        if (gIV.size != gY.size) {return try! "Error: %s: size mismatch %i %i".format(gIV.size, gY.size);}
        // add check for IV to be dtype of int64 or bool
        
        select(gX.dtype, gIV.dtype, gY.dtype) {
            when (DType.Int64, DType.Int64, DType.Int64) {
                var e = toSymEntry(gX,int);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                var y = toSymEntry(gY,int);
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                [(i,v) in zip(iv.a,y.a)] e.a[i] = v;
            }
            when (DType.Float64, DType.Int64, DType.Float64) {
                var e = toSymEntry(gX,real);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                var y = toSymEntry(gY,real);
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                [(i,v) in zip(iv.a,y.a)] e.a[i] = v;
            }
            when (DType.Bool, DType.Int64, DType.Bool) {
                var e = toSymEntry(gX,bool);
                var iv = toSymEntry(gIV,int);
                var iv_min = min reduce iv.a;
                var iv_max = max reduce iv.a;
                var y = toSymEntry(gY,bool);
                if iv_min < 0 {return try! "Error: %s: OOBindex %i < 0".format(pn,iv_min);}
                if iv_max >= e.size {return try! "Error: %s: OOBindex %i > %i".format(pn,iv_min,e.size-1);}
                [(i,v) in zip(iv.a,y.a)] e.a[i] = v;
            }
            otherwise {return notImplementedError(pn,
                                                  "("+dtype2str(gX.dtype)+","+dtype2str(gIV.dtype)+","+dtype2str(gY.dtype)+")");}
        }
        return try! "%s success".format(pn);
    }

    // setSliceIndexToValue "a[slice] = value" response to __setitem__(slice, value)
    // setSliceIndexToPdarray "a[slice] = pdarray" response to __setitem__(slice, pdarray)
    
}
