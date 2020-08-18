module GenSymIO {
  use HDF5;
  use IO;
  use MultiTypeSymbolTable;
  use MultiTypeSymEntry;
  use ServerErrorStrings;
  use FileSystem;
  use Sort;
  use CommAggregation;
  use NumPyDType;
  use List;
  use Map;
  use PrivateDist;

  config const GenSymIO_DEBUG = false;
  config const SEGARRAY_OFFSET_NAME = "segments";
  config const SEGARRAY_VALUE_NAME = "values";
  config const NULL_STRINGS_VALUE = 0:uint(8);
  
  /*
   * Creates a pdarray server-side and returns the SymTab name used to
   * retrieve the pdarray from the SymTab.
   */
  proc arrayMsg(cmd: string, payload: bytes, st: borrowed SymTab): string {
    var repMsg: string;
    var (dtypeBytes, sizeBytes, data) = payload.splitMsgToTuple(3);
    var dtype = str2dtype(try! dtypeBytes.decode());
    var size = try! sizeBytes:int;
    var tmpf:file;

    // Write the data payload that will compose the pdarray to memory buffer
    try {
      tmpf = openmem();
      var tmpw = tmpf.writer(kind=iobig);
      tmpw.write(data);
      try! tmpw.close();
    } catch {
      return "Error: Could not write to memory buffer";
    }
    
    // Get the next name from the SymTab cache
    var rname = st.nextName();

    /*
     * Read the data payload from the memory buffer, encapsulate within
     * a SymEntry, and write to the SymTab cache  
     */
    try {
      var tmpr = tmpf.reader(kind=iobig, start=0);
      if dtype == DType.Int64 {
        var entryInt = new shared SymEntry(size, int);
        tmpr.read(entryInt.a);
        tmpr.close(); tmpf.close();
        st.addEntry(rname, entryInt);
      } else if dtype == DType.Float64 {
        var entryReal = new shared SymEntry(size, real);
        tmpr.read(entryReal.a);
        tmpr.close(); tmpf.close();
        st.addEntry(rname, entryReal);
      } else if dtype == DType.Bool {
        var entryBool = new shared SymEntry(size, bool);
        tmpr.read(entryBool.a);
        tmpr.close(); tmpf.close();
        st.addEntry(rname, entryBool);
      } else if dtype == DType.UInt8 {
        var entryUInt = new shared SymEntry(size, uint(8));
        tmpr.read(entryUInt.a);
        tmpr.close(); tmpf.close();
        st.addEntry(rname, entryUInt);
      } else {
        tmpr.close();
        tmpf.close();
        return try! "Error: Unhandled data type %s".format(dtypeBytes);
      }
      tmpr.close();
      tmpf.close();
    } catch {
      return "Error: Could not read from memory buffer into SymEntry";
    }
    /*
     * Return message indicating the SymTab name corresponding to the
     * newly-created pdarray
     */
    return try! "created " + st.attrib(rname);
  }

  /*
   * Outputs the pdarray as a Numpy ndarray
   */
  proc tondarrayMsg(cmd: string, payload: bytes, st: borrowed SymTab): bytes throws {
    var arrayBytes: bytes;
    var entryStr = payload.decode();
    var entry = st.lookup(entryStr);
    var tmpf: file;
    try {
      tmpf = openmem();
      var tmpw = tmpf.writer(kind=iobig);
      if entry.dtype == DType.Int64 {
        tmpw.write(toSymEntry(entry, int).a);
      } else if entry.dtype == DType.Float64 {
        tmpw.write(toSymEntry(entry, real).a);
      } else if entry.dtype == DType.Bool {
        tmpw.write(toSymEntry(entry, bool).a);
      } else if entry.dtype == DType.UInt8 {
        tmpw.write(toSymEntry(entry, uint(8)).a);
      } else {
        return try! b"Error: Unhandled dtype %s".format(entry.dtype);
      }
      tmpw.close();
    } catch {
      try! tmpf.close();
      return b"Error: Unable to write SymEntry to memory buffer";
    }
    try {
      var tmpr = tmpf.reader(kind=iobig, start=0);
      tmpr.readbytes(arrayBytes);
      tmpr.close();
      tmpf.close();
    } catch {
      return b"Error: Unable to copy array from memory buffer to string";
    }
    //var repMsg = try! "Array: %i".format(arraystr.length) + arraystr;
    /*
      Engin: fwiw, if you want to achieve the above, you can:

        return b"Array: %i %|t".format(arrayBytes.length, arrayBytes);

      But I think the main problem is how to separate the length from the data
    */
    return arrayBytes;
  }

  class DatasetNotFoundError: Error { proc init() {} }
  class NotHDF5FileError: Error { proc init() {} }
  class MismatchedAppendError: Error { proc init() {} }
  class SegArrayError: Error { proc init() {} }

  /*
   * Converts the JSON array to a pdarray
   */
  proc jsonToPdArray(json: string, size: int) throws {
    var f = opentmp();
    var w = f.writer();
    w.write(json);
    w.close();
    var r = f.reader(start=0);
    var array: [0..#size] string;
    r.readf("%jt", array);
    r.close();
    f.close();
    return array;
  }

  /*
   * Spawns a separate Chapel process that executes and returns the 
   * result of the h5ls command
   */
  proc lshdfMsg(cmd: string, payload: bytes, 
                                 st: borrowed SymTab): string throws { 
    // reqMsg: "lshdf [<json_filename>]"
    use Spawn;
    const tmpfile = "/tmp/arkouda.lshdf.output";
    var repMsg: string;
    var (jsonfile) = payload.decode().splitMsgToTuple(1);

    var filename: string;
    try {
      filename = jsonToPdArray(jsonfile, 1)[0];
    } catch {
      return try! "Error: could not decode json filenames via tempfile (%i files: %s)".format(1, jsonfile);
    }

    // Attempt to interpret filename as a glob expression and ls the first result
    var tmp = glob(filename);
    if GenSymIO_DEBUG {
      writeln(try! "glob expanded %s to %i files".format(filename, tmp.size));
    }
    if tmp.size <= 0 {
      return try! "Error: no files matching %s".format(filename);
    }
    filename = tmp[tmp.domain.first];
    var exitCode: int;
    try {
      if exists(tmpfile) {
        remove(tmpfile);
      }
      var cmd = try! "h5ls \"%s\" > \"%s\"".format(filename, tmpfile);
      var sub = spawnshell(cmd);
      // sub.stdout.readstring(repMsg);
      sub.wait();
      exitCode = sub.exit_status;
      var f = open(tmpfile, iomode.r);
      var r = f.reader(start=0);
      r.readstring(repMsg);
      r.close();
      f.close();
      remove(tmpfile);
    } catch {
      return "Error: failed to spawn process and read output";
    }

    if exitCode != 0 {
      return try! "Error: %s".format(repMsg);
    } else {
      return repMsg;
    }
  }

  /* Read dataset from HDF5 files into arkouda symbol table. */
  proc readhdfMsg(cmd: string, payload: bytes, st: borrowed SymTab): string throws {
    var repMsg: string;
    // reqMsg = "readhdf <dsetName> <nfiles> [<json_filenames>]"
    var (dsetName, nfilesStr, jsonfiles) = payload.decode().splitMsgToTuple(3);
    var nfiles = try! nfilesStr:int;
    var filelist: [0..#nfiles] string;
    try {
      filelist = jsonToPdArray(jsonfiles, nfiles);
    } catch {
      return try! "Error: could not decode json filenames via tempfile (%i files: %s)".format(nfiles, jsonfiles);
    }
    var filedom = filelist.domain;
    var filenames: [filedom] string;
    if filelist.size == 1 {
      var tmp = glob(filelist[0]);
      if GenSymIO_DEBUG {
        writeln(try! "glob expanded %s to %i files".format(filelist[0], tmp.size));
      }
      if tmp.size == 0 {
        return try! "Error: no files matching %s".format(filelist[0]);
      }
      // Glob returns filenames in weird order. Sort for consistency
      // sort(tmp);
      filedom = tmp.domain;
      filenames = tmp;
    } else {
      filenames = filelist;
    }

    var segArrayFlags: [filedom] bool;
    var dclasses: [filedom] C_HDF5.hid_t;
    var bytesizes: [filedom] int;
    var signFlags: [filedom] bool;
    for (i, fname) in zip(filedom, filenames) {
      try {
        (segArrayFlags[i], dclasses[i], bytesizes[i], signFlags[i]) = get_dtype(fname, dsetName);
      } catch e: FileNotFoundError {
        return try! "Error: file not found: %s".format(fname);
      } catch e: PermissionError {
        return try! "Error: permission error on %s".format(fname);
      } catch e: DatasetNotFoundError {
        return try! "Error: dataset %s not found in file %s".format(dsetName, fname);
      } catch e: NotHDF5FileError {
        return try! "Error: cannot open as HDF5 file %s".format(fname);
      } catch e: SegArrayError {
        return try! "Error: expected segmented array but could not find sub-datasets '%s' and '%s'".format(SEGARRAY_OFFSET_NAME, SEGARRAY_VALUE_NAME);
      } catch {
        // Need a catch-all for non-throwing function
        return try! "Error: unknown cause";
      }
    }
    const isSegArray = segArrayFlags[filedom.first];
    const dataclass = dclasses[filedom.first];
    const bytesize = bytesizes[filedom.first];
    const isSigned = signFlags[filedom.first];
    for (name, sa, dc, bs, sf) in zip(filenames, segArrayFlags, dclasses, bytesizes, signFlags) {
      if (sa != isSegArray) || (dc != dataclass) || (bs != bytesize) || (sf != isSigned) {
        return try! "Error: inconsistent dtype in dataset %s of file %s".format(dsetName, name);
      }
    }
    if GenSymIO_DEBUG {
      writeln("Verified all dtypes across files");
    }
    var subdoms: [filedom] domain(1);
    var segSubdoms: [filedom] domain(1);
    var len: int;
    var nSeg: int;
    try {
      if isSegArray {
        (segSubdoms, nSeg) = get_subdoms(filenames, dsetName + "/" + SEGARRAY_OFFSET_NAME);
        (subdoms, len) = get_subdoms(filenames, dsetName + "/" + SEGARRAY_VALUE_NAME);
      } else {
        (subdoms, len) = get_subdoms(filenames, dsetName);
      }
    } catch e: HDF5RankError {
      return notImplementedError("readhdf", try! "Rank %i arrays".format(e.rank));
    } catch {
      return try! "Error: unknown cause";
    }
    if GenSymIO_DEBUG {
      writeln("Got subdomains and total length");
    }

    select (isSegArray, dataclass) {
    when (true, C_HDF5.H5T_INTEGER) {
      if (bytesize != 1) || isSigned {
        return try! "Error: detected unhandled datatype: segmented? %t, class %i, size %i, signed? %t".format(isSegArray, dataclass, bytesize, isSigned);
      }
      var entrySeg = new shared SymEntry(nSeg, int);
      read_files_into_distributed_array(entrySeg.a, segSubdoms, filenames, dsetName + "/" + SEGARRAY_OFFSET_NAME);
      fixupSegBoundaries(entrySeg.a, segSubdoms, subdoms);
      var entryVal = new shared SymEntry(len, uint(8));
      read_files_into_distributed_array(entryVal.a, subdoms, filenames, dsetName + "/" + SEGARRAY_VALUE_NAME);

      var segName = st.nextName();
      st.addEntry(segName, entrySeg);
      var valName = st.nextName();
      st.addEntry(valName, entryVal);
      var newString = true;
      var stringsList: list(string, parSafe=true);
      var charList: list(uint(8), parSafe=true);
      for entry in entryVal.a do {
        if entry == 0:uint(8) {
            newString = true;
            try! stringsList.append(createStringWithNewBuffer(c_ptrTo(charList.toArray()), 
                   charList.size-1, charList.size));
          } else {
            if newString {
              charList.clear();
                newString = false;
          } 
          charList.append(entry);
        }
      }
      return try! "created " + st.attrib(segName) + " +created " + st.attrib(valName);
    }
    when (false, C_HDF5.H5T_INTEGER) {
      var entryInt = new shared SymEntry(len, int);
      if GenSymIO_DEBUG {
        writeln("Initialized int entry"); try! stdout.flush();
      }
      read_files_into_distributed_array(entryInt.a, subdoms, filenames, dsetName);
      var rname = st.nextName();
      st.addEntry(rname, entryInt);
      return try! "created " + st.attrib(rname);
    }
    when (false, C_HDF5.H5T_FLOAT) {
      var entryReal = new shared SymEntry(len, real);
      if GenSymIO_DEBUG {
        writeln("Initialized float entry"); try! stdout.flush();
      }
      read_files_into_distributed_array(entryReal.a, subdoms, filenames, dsetName);
      var rname = st.nextName();
      st.addEntry(rname, entryReal);
      return try! "created " + st.attrib(rname);
    }
    otherwise {
      return try! "Error: detected unhandled datatype: segmented? %t, class %i, size %i, signed? %t".format(isSegArray, dataclass, bytesize, isSigned);
    }
    }
  }

  /* 
   * Reads all datasets from 1..n HDF5 files into an Arkouda symbol table. 
   */
  proc readAllHdfMsg(cmd: string, payload: bytes, st: borrowed SymTab): string throws {
    // reqMsg = "readAllHdf <ndsets> <nfiles> [<json_dsetname>] | [<json_filenames>]"
    var repMsg: string;
    // May need a more robust delimiter then " | "
    var (ndsetsStr, nfilesStr, arraysStr) = payload.decode().splitMsgToTuple(3);
    var (jsondsets, jsonfiles) = arraysStr.splitMsgToTuple(" | ",2);
    var ndsets = try! ndsetsStr:int;
    var nfiles = try! nfilesStr:int;
    var dsetlist: [0..#ndsets] string;
    var filelist: [0..#nfiles] string;
    try {
      dsetlist = jsonToPdArray(jsondsets, ndsets);
    } catch {
      return try! "Error: could not decode json dataset names via tempfile (%i files: %s)".format(ndsets, jsondsets);
    }
    try {
      filelist = jsonToPdArray(jsonfiles, nfiles);
    } catch {
      return try! "Error: could not decode json filenames via tempfile (%i files: %s)".format(nfiles, jsonfiles);
    }
    var dsetdom = dsetlist.domain;
    var filedom = filelist.domain;
    var dsetnames: [dsetdom] string;
    var filenames: [filedom] string;
    dsetnames = dsetlist;
    if filelist.size == 1 {
      var tmp = glob(filelist[0]);
      if GenSymIO_DEBUG {
        writeln(try! "glob expanded %s to %i files".format(filelist[0], tmp.size));
      }
      if tmp.size == 0 {
        return try! "Error: no files matching %s".format(filelist[0]);
      }
      // Glob returns filenames in weird order. Sort for consistency
      // sort(tmp);
      filedom = tmp.domain;
      filenames = tmp;
    } else {
      filenames = filelist;
    }
    var segArrayFlags: [filedom] bool;
    var dclasses: [filedom] C_HDF5.hid_t;
    var bytesizes: [filedom] int;
    var signFlags: [filedom] bool;
    var rnames: string;
    for dsetName in dsetnames do {
      for (i, fname) in zip(filedom, filenames) {
        try {
          (segArrayFlags[i], dclasses[i], bytesizes[i], signFlags[i]) = get_dtype(fname, dsetName);
        } catch e: FileNotFoundError {
          return try! "Error: file not found: %s".format(fname);
        } catch e: PermissionError {
          return try! "Error: permission error on %s".format(fname);
        } catch e: DatasetNotFoundError {
          return try! "Error: dataset %s not found in file %s".format(dsetName, fname);
        } catch e: NotHDF5FileError {
          return try! "Error: cannot open as HDF5 file %s".format(fname);
        } catch e: SegArrayError {
          return try! "Error: expecte segmented array but could not find sub-datasets '%s' and '%s'".format(SEGARRAY_OFFSET_NAME, SEGARRAY_VALUE_NAME);
        } catch {
          // Need a catch-all for non-throwing function
          return try! "Error: unknown cause";
        }
      }
      const isSegArray = segArrayFlags[filedom.first];
      const dataclass = dclasses[filedom.first];
      const bytesize = bytesizes[filedom.first];
      const isSigned = signFlags[filedom.first];
      for (name, sa, dc, bs, sf) in zip(filenames, segArrayFlags, dclasses, bytesizes, signFlags) {
        if (sa != isSegArray) || (dc != dataclass) || (bs != bytesize) || (sf != isSigned) {
          return try! "Error: inconsistent dtype in dataset %s of file %s".format(dsetName, name);
        }
      }
      if GenSymIO_DEBUG {
        writeln("Verified all dtypes across files for dataset ", dsetName);
      }
      var subdoms: [filedom] domain(1);
      var segSubdoms: [filedom] domain(1);
      var len: int;
      var nSeg: int;
      try {
        if isSegArray {
          (segSubdoms, nSeg) = get_subdoms(filenames, dsetName + "/" + SEGARRAY_OFFSET_NAME);
          (subdoms, len) = get_subdoms(filenames, dsetName + "/" + SEGARRAY_VALUE_NAME);
        } else {
          (subdoms, len) = get_subdoms(filenames, dsetName);
        }
      } catch e: HDF5RankError {
        return notImplementedError("readhdf", try! "Rank %i arrays".format(e.rank));
      } catch {
        return try! "Error: unknown cause";
      }
      if GenSymIO_DEBUG {
        writeln("Got subdomains and total length for dataset ", dsetName);
      }
      select (isSegArray, dataclass) {
        when (true, C_HDF5.H5T_INTEGER) {
          if (bytesize != 1) || isSigned {
            return try! "Error: detected unhandled datatype: segmented? %t, class %i, size %i, signed? %t".format(isSegArray, dataclass, bytesize, isSigned);
          }
          var entrySeg = new shared SymEntry(nSeg, int);
          read_files_into_distributed_array(entrySeg.a, segSubdoms, filenames, dsetName + "/" + SEGARRAY_OFFSET_NAME);
          fixupSegBoundaries(entrySeg.a, segSubdoms, subdoms);
          var entryVal = new shared SymEntry(len, uint(8));
          read_files_into_distributed_array(entryVal.a, subdoms, filenames, dsetName + "/" + SEGARRAY_VALUE_NAME);
          var segName = st.nextName();
          st.addEntry(segName, entrySeg);
          var valName = st.nextName();
          st.addEntry(valName, entryVal);
          rnames = rnames + "created " + st.attrib(segName) + " +created " + st.attrib(valName) + " , ";
        }
        when (false, C_HDF5.H5T_INTEGER) {
          var entryInt = new shared SymEntry(len, int);
          if GenSymIO_DEBUG {
            writeln("Initialized int entry for dataset ", dsetName); try! stdout.flush();
          }
          read_files_into_distributed_array(entryInt.a, subdoms, filenames, dsetName);
          var rname = st.nextName();
          st.addEntry(rname, entryInt);
          rnames = rnames + "created " + st.attrib(rname) + " , ";
        }
        when (false, C_HDF5.H5T_FLOAT) {
          var entryReal = new shared SymEntry(len, real);
          if GenSymIO_DEBUG {
            writeln("Initialized float entry"); try! stdout.flush();
          }
          read_files_into_distributed_array(entryReal.a, subdoms, filenames, dsetName);
          var rname = st.nextName();
          st.addEntry(rname, entryReal);
          rnames = rnames + "created " + st.attrib(rname) + " , ";
        }
        otherwise {
          return try! "Error: detected unhandled datatype: segmented? %t, class %i, size %i, signed? %t".format(isSegArray, dataclass, bytesize, isSigned);
        }
      }
    }
    return try! rnames.strip(" , ", leading = false, trailing = true);
  }

  proc fixupSegBoundaries(a: [?D] int, segSubdoms: [?fD] domain(1), valSubdoms: [fD] domain(1)) {
    var boundaries: [fD] int; // First index of each region that needs to be raised
    var diffs: [fD] int; // Amount each region must be raised over previous region
    forall (i, sd, vd, b) in zip(fD, segSubdoms, valSubdoms, boundaries) {
      b = sd.low; // Boundary is index of first segment in file
      // Height increase of next region is number of bytes in current region
      if (i < fD.high) {
        diffs[i+1] = vd.size;
      }
    }
    // Insert height increases at region boundaries
    var sparseDiffs: [D] int;
    forall (b, d) in zip(boundaries, diffs) with (var agg = newDstAggregator(int)) {
      agg.copy(sparseDiffs[b], d);
    }
    // Make plateaus from peaks
    var corrections = + scan sparseDiffs;
    // Raise the segment offsets by the plateaus
    a += corrections;
  }

  /* Get the class of the HDF5 datatype for the dataset. */
  proc get_dtype(filename: string, dsetName: string) throws {
    const READABLE = (S_IRUSR | S_IRGRP | S_IROTH);
    if !exists(filename) {
      throw new owned FileNotFoundError();
    }
    if !(getMode(filename) & READABLE) {
      throw new owned PermissionError();
    }
    var file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
    if file_id < 0 { // HF5open returns negative value on failure
      throw new owned NotHDF5FileError();
    }
    if !C_HDF5.H5Lexists(file_id, dsetName.c_str(), C_HDF5.H5P_DEFAULT) {
      throw new owned DatasetNotFoundError();
    }
    var dataclass: C_HDF5.H5T_class_t;
    var bytesize: int;
    var isSigned: bool;
    var isSegArray: bool;
    try {
      (dataclass, bytesize, isSigned) = get_dataset_info(file_id, dsetName);
      isSegArray = false;
    } catch e:DatasetNotFoundError {
      var group = C_HDF5.H5Gopen2(file_id, dsetName.c_str(), C_HDF5.H5P_DEFAULT);
      if (group < 0) {
        // 
        try! writeln("The dataset is neither at the root of the HDF5 file not within a group");
        throw new owned SegArrayError();
      }
      var offsetDset = dsetName + "/" + SEGARRAY_OFFSET_NAME;
      var valueDset = dsetName + "/" + SEGARRAY_VALUE_NAME;
      var (offsetClass, offsetByteSize, offsetSign) = try get_dataset_info(file_id, offsetDset);
      if (offsetClass != C_HDF5.H5T_INTEGER) {
        throw new owned SegArrayError();
      }
      try (dataclass, bytesize, isSigned) = get_dataset_info(file_id, valueDset);
      isSegArray = true;
    } catch e {
      throw e;
    }
    C_HDF5.H5Fclose(file_id);
    return (isSegArray, dataclass, bytesize, isSigned);
  }

  proc get_dataset_info(file_id, dsetName) throws {
    var dset = C_HDF5.H5Dopen(file_id, dsetName.c_str(), C_HDF5.H5P_DEFAULT);
    if (dset < 0) {
      throw new owned DatasetNotFoundError();
    }
    var datatype = C_HDF5.H5Dget_type(dset);
    var dataclass = C_HDF5.H5Tget_class(datatype);
    var bytesize = C_HDF5.H5Tget_size(datatype):int;
    var isSigned = (C_HDF5.H5Tget_sign(datatype) == C_HDF5.H5T_SGN_2);
    C_HDF5.H5Tclose(datatype);
    C_HDF5.H5Dclose(dset);
    return (dataclass, bytesize, isSigned);
  }

  class HDF5RankError: Error {
    var rank: int;
    var filename: string;
    var dsetName: string;
  }

  /*
   *  Get the subdomains of the distributed array represented by each file, 
   *  as well as the total length of the array. 
   */
  proc get_subdoms(filenames: [?FD] string, dsetName: string) throws {
    use SysCTypes;

    var lengths: [FD] int;
    for (i, filename) in zip(FD, filenames) {
      var file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
      var dims: [0..#1] C_HDF5.hsize_t; // Only rank 1 for now
//      var dsetRank: c_int;
//      // Verify 1D array
//      C_HDF5.H5LTget_dataset_ndims(file_id, dsetName.c_str(), dsetRank);
//      if dsetRank != 1 {
//        // TODO: change this to a throw
//        // halt("Expected 1D array, got rank " + dsetRank);
//        throw new owned HDF5RankError(dsetRank, filename, dsetName);
//      }
      // Read array length into dims[0]
      C_HDF5.HDF5_WAR.H5LTget_dataset_info_WAR(file_id, dsetName.c_str(), c_ptrTo(dims), nil, nil);
      C_HDF5.H5Fclose(file_id);
      lengths[i] = dims[0]: int;
    }
    // Compute subdomain of master array contained in each file
    var subdoms: [FD] domain(1);
    var offset = 0;
    for i in FD {
      subdoms[i] = {offset..#lengths[i]};
      offset += lengths[i];
    }
    return (subdoms, (+ reduce lengths));
  }

  /* This function gets called when A is a BlockDist or DefaultRectangular array. */
  proc read_files_into_distributed_array(A, filedomains: [?FD] domain(1), filenames: [FD] string, dsetName: string)
    where (MyDmap == Dmap.blockDist || MyDmap == Dmap.defaultRectangular) {
    if GenSymIO_DEBUG {
      writeln("entry.a.targetLocales() = ", A.targetLocales()); try! stdout.flush();
      writeln("Filedomains: ", filedomains); try! stdout.flush();
    }
    coforall loc in A.targetLocales() do on loc {
        // Create local copies of args
        var locFiles = filenames;
        var locFiledoms = filedomains;
        var locDset = dsetName;
        /* On this locale, find all files containing data that belongs in
           this locale's chunk of A */
        for (filedom, filename) in zip(locFiledoms, locFiles) {
          var isopen = false;
          var file_id: C_HDF5.hid_t;
          var dataset: C_HDF5.hid_t;
          // Look for overlap between A's local subdomains and this file
          for locdom in A.localSubdomains() {
            const intersection = domain_intersection(locdom, filedom);
            if intersection.size > 0 {
              // Only open the file once, even if it intersects with many local subdomains
              if !isopen {
                file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
                dataset = C_HDF5.H5Dopen(file_id, locDset.c_str(), C_HDF5.H5P_DEFAULT);
                isopen = true;
              }
              // do A[intersection] = file[intersection - offset]
              var dataspace = C_HDF5.H5Dget_space(dataset);
              var dsetOffset = [(intersection.low - filedom.low): C_HDF5.hsize_t];
              var dsetStride = [intersection.stride: C_HDF5.hsize_t];
              var dsetCount = [intersection.size: C_HDF5.hsize_t];
              C_HDF5.H5Sselect_hyperslab(dataspace, C_HDF5.H5S_SELECT_SET, c_ptrTo(dsetOffset), c_ptrTo(dsetStride), c_ptrTo(dsetCount), nil);
              var memOffset = [0: C_HDF5.hsize_t];
              var memStride = [1: C_HDF5.hsize_t];
              var memCount = [intersection.size: C_HDF5.hsize_t];
              var memspace = C_HDF5.H5Screate_simple(1, c_ptrTo(memCount), nil);
              C_HDF5.H5Sselect_hyperslab(memspace, C_HDF5.H5S_SELECT_SET, c_ptrTo(memOffset), c_ptrTo(memStride), c_ptrTo(memCount), nil);
              if GenSymIO_DEBUG {
                writeln("Locale ", loc, ", intersection ", intersection, ", dataset slice ", (intersection.low - filedom.low, intersection.high - filedom.low));
              }
              // The fact that intersection is a subset of a local subdomain means there should be no communication in the read
              local {
                C_HDF5.H5Dread(dataset, getHDF5Type(A.eltType), memspace, dataspace, C_HDF5.H5P_DEFAULT, c_ptrTo(A.localSlice(intersection)));
              }
              C_HDF5.H5Sclose(memspace);
              C_HDF5.H5Sclose(dataspace);
            }
          }
          if isopen {
            C_HDF5.H5Dclose(dataset);
            C_HDF5.H5Fclose(file_id);
          }
        }
      }
  }

  /* This function is called when A is a CyclicDist array. */
  proc read_files_into_distributed_array(A, filedomains: [?FD] domain(1), filenames: [FD] string, dsetName: string)
    where (MyDmap == Dmap.cyclicDist) {
    use CyclicDist;
    // Distribute filenames across locales, and ensure single-threaded reads on each locale
    var fileSpace: domain(1) dmapped Cyclic(startIdx=FD.low, dataParTasksPerLocale=1) = FD;
    forall fileind in fileSpace with (ref A) {
      var filedom: subdomain(A.domain) = filedomains[fileind];
      var filename = filenames[fileind];
      var file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
      // TODO: use select_hyperslab to read directly into a strided slice of A
      // Read file into a temporary array and copy into the correct chunk of A
      var AA: [1..filedom.size] A.eltType;
      readHDF5Dataset(file_id, dsetName, AA);
      A[filedom] = AA;
      C_HDF5.H5Fclose(file_id);
    }
  }

  proc domain_intersection(d1: domain(1), d2: domain(1)) {
    var low = max(d1.low, d2.low);
    var high = min(d1.high, d2.high);
    if (d1.stride !=1) && (d2.stride != 1) {
      //TODO: change this to throw
      halt("At least one domain must have stride 1");
    }
    var stride = max(d1.stride, d2.stride);
    return {low..high by stride};
  }

  proc tohdfMsg(cmd: string, payload: bytes, st: borrowed SymTab): string throws {
    var (arrayName, dsetName, modeStr, jsonfile)
          = payload.decode().splitMsgToTuple(4);

    var mode = try! modeStr: int;
    var filename: string;
    var entry = st.lookup(arrayName);

    try {
      filename = jsonToPdArray(jsonfile, 1)[0];
    } catch {
      return try! "Error: could not decode json filenames via tempfile (%i files: %s)".format(1, jsonfile);
    }

    var warnFlag: bool;
    try {
    select entry.dtype {
      when DType.Int64 {
        var e = toSymEntry(entry, int);
        warnFlag = write1DDistArray(filename, mode, dsetName, e.a, DType.Int64);
      }
      when DType.Float64 {
        var e = toSymEntry(entry, real);
        warnFlag = write1DDistArray(filename, mode, dsetName, e.a, DType.Float64);
      }
      when DType.Bool {
        var e = toSymEntry(entry, bool);
        warnFlag = write1DDistArray(filename, mode, dsetName, e.a, DType.Bool);
      }
      when DType.UInt8 {
        var e = toSymEntry(entry, uint(8));
        warnFlag = write1DDistArray(filename, mode, dsetName, e.a, DType.UInt8);
      } otherwise {
        return unrecognizedTypeError("tohdf", dtype2str(entry.dtype));
      }
    }
    } catch e: FileNotFoundError {
      return try! "Error: unable to open file for writing: %s".format(filename);
    } catch e: MismatchedAppendError {
      return "Error: appending to existing files must be done with the same number of locales. Try saving with a different directory or filename prefix?";
    } catch e: Error {
      return "Error: problem writing to file %s".format(e) ;
    }
    if warnFlag {
      return "Warning: possibly overwriting existing files matching filename pattern";
    } else {
      return "wrote array to file";
    }
  }

  proc write1DDistArray(filename: string, mode: int, dsetName: string, A, array_type: DType) throws {
    /* Output is 1 file per locale named <filename>_<loc>, and a dataset
       named <dsetName> is created in each one. If mode==1 (append) and the
       correct number of files already exists, then a new dataset named
       <dsetName> will be created in each. Strongly recommend only using
       append mode to write arrays with the same domain. */

    var warnFlag = false;
    const fields = filename.split(".");
    var prefix:string;
    var extension:string;

    if fields.size == 1 {
      prefix = filename;
      extension = "";
    } else {
      prefix = ".".join(fields#(fields.size-1)); // take all but the last
      extension = "." + fields[fields.domain.high];
    }
    
    // Generate the filenames based upon the number of targetLocales.
    var filenames: [0..#A.targetLocales().size] string;
    for i in 0..#A.targetLocales().size {
      filenames[i] = try! "%s_LOCALE%s%s".format(prefix, i:string, extension);
    }

    var matchingFilenames = glob(try! "%s_LOCALE*%s".format(prefix, extension));
    // if appending, make sure number of files hasn't changed and all are present
    if (mode == 1) {
      var allexist = true;
      for f in filenames {
        allexist &= try! exists(f);
      }
      if !allexist || (matchingFilenames.size != filenames.size) {
        throw new owned MismatchedAppendError();
      }
    } else { // if truncating, create new file per locale
      if matchingFilenames.size > 0 {
        warnFlag = true;
      }
      for loc in 0..#A.targetLocales().size {
        // when done with a coforall over locales, only locale 0's file gets created correctly.
        // The other locales' files have corrupted headers.
        //filenames[loc] = try! "%s_LOCALE%s%s".format(prefix, loc:string, extension);
        var file_id: C_HDF5.hid_t;
        if GenSymIO_DEBUG {
          writeln("Creating or truncating file");
        }

        file_id = C_HDF5.H5Fcreate(filenames[loc].c_str(), C_HDF5.H5F_ACC_TRUNC, 
                                                         C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);

        if file_id < 0 { // Negative file_id means error
          throw new owned FileNotFoundError();
        }
          /*
           * If DType is UInt8, need to create strings_array group to enable read/load with the
           * Arkouda infrastructure. The strings_array group contains two datasets: (1) segments, 
           * which are the indices for the string values embedded in the string binary and (2)
           * values, which are the corresponding string values within a null-delimited bytes object
           */ 
           if array_type == DType.UInt8 {
             var group_id = C_HDF5.H5Gcreate2(file_id, "/strings_array", C_HDF5.H5P_DEFAULT, 
                                              C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
             C_HDF5.H5Gclose(group_id);
        }
        C_HDF5.H5Fclose(file_id);
      }
    }

    /*
     * Declare the indices object, which is a globally-scoped PrivateSpace array that
     * contains the slice index for each locale. Each slice index is used to remove 
     * the uint(8) characters moved to the previous locale, which is done when a 
     * string, which is an array of uint(8) chars, spans two locales.
     */
    var indices: [PrivateSpace] int;
    
    /*
     * If this is a strings dataset, loop through all locales and set the slice indices, 
     * which are used to remove uint(8) characters from the locale slice that are part 
     * of a string that belongs to the previous locale in the pdarray list of locales.
     */
    if isStringsDataset(dsetName) {
      coforall (loc, idx) in zip(A.targetLocales(), 
                                       filenames.domain) with(ref indices) do on loc {
      if idx < A.targetLocales().size-1 {
          const locDom = A.localSubdomain();
          if A.localSlice(locDom).back() != NULL_STRINGS_VALUE {
            generateSliceIndex(idx,indices,A);
          }
        }
      }
    }

    coforall (loc, idx) in zip(A.targetLocales(), 
                                        filenames.domain) with(ref indices) do on loc {
        const myFilename = filenames[idx];
        if GenSymIO_DEBUG {
          writeln(try! "%s exists? %t".format(myFilename, exists(myFilename)));
        }
        var myFileID = C_HDF5.H5Fopen(myFilename.c_str(), C_HDF5.H5F_ACC_RDWR, 
                                                                    C_HDF5.H5P_DEFAULT);
        const locDom = A.localSubdomain();
        var dims: [0..#1] C_HDF5.hsize_t;
        dims[0] = locDom.size: C_HDF5.hsize_t;
        var myDsetName = "/" + dsetName;
               
        use C_HDF5.HDF5_WAR;

        /*
         * A strings dataset is handled differently because a string can span multiple
         * locales since each string is composed of 1..n uint(8) characters. Accodingly,
         * the first step in writing the local slice to hdf5 is to verify if this is
         * indeed a strings dataset.
         */
        if isStringsDataset(dsetName) {  
            /*
             * Since this is a strings dataset, there is a possibility that 1..n
             * strings span two neighboring locales; this possibility is checked by
             * seeing if the final character in the local slice is the null uint(8)
             * character. If it is not, then the last string is only a partial string.
             */
            if A.localSlice(locDom).back() != NULL_STRINGS_VALUE {
              /*
               * Since the last value of the local slice is other than the uint(8) null
               * character, this means the last string in the current, local slice spans 
               * the current AND next locale. Consequently, need to do the following:
               * 1. Add all current locale slice values to a list
               * 2. Obtain remaining uint(8) values from the next locale
               */
              var charList = convertLocalSliceToList(A, locDom); 

              /*
               * On the next locale do the following:
               * 
               * 1. Retrieve the non-null uint(8) chars followed by the null
               *    uint(8) characters from the start of the local slice
               * 2. Add to the newly-created charList
               */
              on Locales[idx+1] {
                const locDom = A.localSubdomain();

                /*
                 * Iterate through the local slice values for the next locale and add
                 * each to the charList, which is the local slice corresponding to the
                 * current locale, until the null uint(8) character is reached. This 
                 * subset of chars corresponds to the chars that complete the string 
                 * at the end of the current locale
                 */
                for (value, i) in zip(A.localSlice(locDom), 
                                                    0..A.localSlice(locDom).size-1) {
                  if value != NULL_STRINGS_VALUE {
                    charList.append(value:uint(8));
                  } else {
                    break;
                  }
                }
              }

              /* 
               * To prepare for writing revised values array to hdf5, do the following:
               * 1. Add null uint(8) char to the end of the array so reads work correctly
               * 2. Set the dims[0] value, which is the revised length of the valuesList
               */
              charList.append(NULL_STRINGS_VALUE);
          
              var sliceIndex = indices[idx]:int;
              var valuesList: list(uint(8), parSafe=true);

              /*
               * Now check to see if the current locale contains chars from the previous 
               * locale by checking the sliceIndex. If the sliceIndex > -1, this means that 
               * the charList contains chars that compose the last string from the previous 
               * locale. If so, generate a new valuesList that has those values sliced
               * from the charList
               */
              if sliceIndex > -1 {
                valuesList = adjustForStringSlices(sliceIndex, charList);
              } else {
                valuesList = charList;
              }

              // Update the dimensions per the possibly re-sized valuesList
              dims[0] = valuesList.size:uint(64);

              /*
               * Generate the segmentsList from the full-processed valuesList by
               * first specifying the first index of zero, and then subsequent
               * indices mapping to the locations of null uint(8) characters
               */
              var segmentsList = generateSegmentsList(valuesList); 
 
              /*
               * Write the valuesList containing the uint(8) characters missing from
               * the local slice along with retrieved from the next locale to hdf5
               */
              H5LTmake_dataset_WAR(myFileID, '/strings_array/values'.c_str(), 1, 
                    c_ptrTo(dims), getHDF5Type(A.eltType), c_ptrTo(valuesList.toArray()));     

              H5LTmake_dataset_WAR(myFileID, '/strings_array/segments'.c_str(), 1, 
                       c_ptrTo([segmentsList.size:uint(64)]), getHDF5Type(int), 
                       c_ptrTo(segmentsList.toArray()));   
            } else {
              /*
               * The local slice ends with the uint(8) null character, which is the 
               * required value to ensure correct read logic, so next check to see if 
               * this local slice contains 1..n chars that compose a string from the 
               * previous locale.
               */
              var sliceIndex = indices[idx]:int;

              if sliceIndex == -1 {
                /*
                 * The local slice does not contain chars from previous locale, so generate
                 * the segments list and write the values and segments arrays out to hdf5
                 */ 
                var segmentsList = generateSegmentsList(A.localSlice(locDom));

                H5LTmake_dataset_WAR(myFileID, '/strings_array/segments'.c_str(), 1, 
                                   c_ptrTo([segmentsList.size:uint(64)]),getHDF5Type(int), 
                                   c_ptrTo(segmentsList.toArray()));  
                H5LTmake_dataset_WAR(myFileID, '/strings_array/values'.c_str(), 1, 
                                   c_ptrTo(dims), getHDF5Type(A.eltType), 
                                   c_ptrTo(A.localSlice(locDom)));   
              } else {
                /*
                 * The local slice does contain chars from previous locale, first adjust by
                 * slicing those chars out to generate a values list, generate the segments 
                 * list and then finally write the values and segments arrays out to hdf5
                 */ 
                var charList = convertLocalSliceToList(A, locDom);

                var valuesList = adjustForStringSlices(sliceIndex, charList);
                var segmentsList = generateSegmentsList(valuesList); 

                // Update the dimensions per the possibly re-sized valuesList
                dims[0] = valuesList.size:uint(64);

                H5LTmake_dataset_WAR(myFileID, '/strings_array/segments'.c_str(), 1, 
                              c_ptrTo([segmentsList.size:uint(64)]),getHDF5Type(int), 
                              c_ptrTo(segmentsList.toArray()));  
                H5LTmake_dataset_WAR(myFileID, '/strings_array/values'.c_str(), 1, 
                              c_ptrTo(dims), getHDF5Type(A.eltType),
                              c_ptrTo(valuesList.toArray()));   
              }
            }
        } else {
            /*
             * This is not a strings pdarray, so simply write the local slice out to the
             * top-level group of the hdf5 file
             */
             H5LTmake_dataset_WAR(myFileID, myDsetName.c_str(), 1, c_ptrTo(dims),
                                     getHDF5Type(A.eltType), c_ptrTo(A.localSlice(locDom)));
        }
        // Close the file now that the pdarray has been written
        C_HDF5.H5Fclose(myFileID);
    }
    return warnFlag;
  }

  /*
   * Generates the slice index for the locale strings array and adds it to the 
   * indices parameter. Note: the slice index will be used to remove characters from 
   * the current locale that correspond to the last string of the previous locale.
   */
  private inline proc generateSliceIndex(idx : int, indices, A) {
    on Locales[idx+1] {
      const locDom = A.localSubdomain();
      var sliceIndex = -1;

      /*
       * Filter out the non-null uint(8) characters, which are the characters
       * that complete the last string started in the previous locale, along with
       * the null uint(8) character so the slice starts at the first non-null 
       * uint(8) character, which is the start of the first string to be assigned 
       * to the hdf5 file corresponding to this locale.
       */
      for (value, i) in zip(A.localSlice(locDom), 0..A.localSlice(locDom).size-1) {
        if value == NULL_STRINGS_VALUE {
          /*
           * Since the char is the null uint(8) character, that means that the chars
           * composing the last string from the previous locale have been accounted
           * for, so update the slice index and then breakout from the for loop.
           */
          sliceIndex = i + 1;
          break;
        }
      }
      // Assign the slice index to this locale id in the indices PrivateDist
      indices[here.id] = sliceIndex;
    }
  }

  /*
   * Converts a local slice into a uint(8) list for use in methods that add
   * or remove entries from the resulting list.
   */
  private inline proc convertLocalSliceToList(A, locDom) : list(uint(8)) {
    var charList: list(uint(8), parSafe=true);
    for value in A.localSlice(locDom) {
     charList.append(value:uint(8));
    }
    return charList;
  }
  
  /*
   * Adjusts the list of uint(8) characters by removing leading chars
   * that correspond to 1..n chars that compose a string started in the
   * previous locale by slicing those chars out and returning a new list.
   */
  private inline proc adjustForStringSlices(sliceIndex : int, 
                                   charList : list(uint(8))) : list(uint(8)){
    var valuesList: list(uint(8), parSafe=true);
    for value in charList(sliceIndex..charList.size-1) {
      valuesList.append(value:uint(8));
    }
    return valuesList;
  }
  
  /*
   * Generates a list of segments, or indices to the start location
   * of each string within a uint(8) array. The segmentsList will be 
   * written to the hdf5 file as the segments array.
   */
  private inline proc generateSegmentsList(valuesList) : list(int) {
    var segmentsList: list(int, parSafe=true);

    /*
     * The valuesList starts with non-null uint(8) char, so
     * add zero index to mark the start of the first string
     */
    segmentsList.append(0);

    for (value, i) in zip(valuesList,0..valuesList.size-1) do {
      /*
       * If the value is a null uint(8) character, then the next
       * string sequence will start at the next list position,
       * so append sequences with current position + 1
       */
       if (value == NULL_STRINGS_VALUE) && (i < valuesList.size-1) {
         segmentsList.append(i+1);
       }
    }
    return segmentsList;
  }

  /*
   * Prepares the HDF5 file to hold a Strings array
   */
  private inline proc prepareStringsFile(fileId : int) {
    var group_id = try! C_HDF5.H5Gcreate2(fileId, "/strings_array", 
               C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT); 
    C_HDF5.H5Gclose(group_id);
  }

  /*
   * Returns a boolean indicating whether the data set is a Strings values 
   * dataset corresponding to a Strings array save operation.
   */
  private inline proc isStringsDataset(dsetName: string) : bool {
    return dsetName.find(needle="strings_array/values") > -1;
  }
}
