/*
 * If we create temporary objects but then don't explicitly drop them they end
 * up as part of the extension, which means when they ultimately get dropped
 * when the session ends the extension gets dropped as well. Just create an
 * explicit temporary schema instead.
 */
CREATE SCHEMA "panda_post Temp Schema";

CREATE TYPE ndarray;

SET client_min_messages = WARNING;
CREATE FUNCTION ndarray_in(cstring) RETURNS ndarray LANGUAGE INTERNAL IMMUTABLE STRICT AS 'byteain';
CREATE FUNCTION ndarray_out(ndarray) RETURNS cstring LANGUAGE INTERNAL IMMUTABLE STRICT AS 'byteaout';
SET client_min_messages = NOTICE;

CREATE TYPE ndarray(
  INPUT = ndarray_in
  , OUTPUT = ndarray_out
  , LIKE = pg_catalog.bytea
);

/*
 * Stable in case we create a new storage version and the function dynamically
 * updates to it.
 */
CREATE FUNCTION ndarray_to_plpython(internal) RETURNS internal LANGUAGE c STABLE STRICT
  AS '$libdir/panda_post', 'PLyNdarray_FromDatum';
CREATE FUNCTION ndarray_from_plpython(internal) RETURNS ndarray LANGUAGE c STABLE STRICT
  AS '$libdir/panda_post', 'PLyObject_To_ndarray';

CREATE TRANSFORM FOR ndarray LANGUAGE plpythonu(
  FROM SQL WITH FUNCTION ndarray_to_plpython(internal)
  , TO SQL WITH FUNCTION ndarray_from_plpython(internal)
);

CREATE FUNCTION create_cast(
  data_type text
  , transform text DEFAULT ''
  , cast_type text DEFAULT NULL
  , create_array_cast boolean DEFAULT true
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  c_regtype CONSTANT regtype := data_type;
  -- plpython creates a python function named after the PG function, so we can't have spaces
  c_clean_type CONSTANT text := replace( data_type, ' ', '_' );
  c_cast_type CONSTANT text := coalesce( 'AS ' || cast_type, '' );

  -- ERROR FORMAT
  c_error_fmt CONSTANT text := format(
$fmt$
if i.ndim > 0:
  raise plpy.Error('Can not cast ndarray with more than one element to %1$s')
$fmt$
    , data_type
  );

  -- TO FORMAT
  c_to_fmt CONSTANT text := $fmt$
CREATE FUNCTION ndarray_to_%1$s%7$s(
  i ndarray
) RETURNS %8$s%2$s LANGUAGE plpythonu IMMUTABLE STRICT
TRANSFORM FOR TYPE ndarray
%3$s
AS $func$
import numpy as np
%5$s
return i%6$s
$func$;
CREATE CAST (ndarray AS %8$s%2$s) WITH FUNCTION ndarray_to_%1$s%7$s(ndarray) %4$s;
$fmt$;

  -- FROM FORMAT
  c_from_fmt CONSTANT text := $fmt$
CREATE FUNCTION ndarray_from_%1$s(
  i %5$s%2$s
) RETURNS ndarray LANGUAGE plpythonu IMMUTABLE STRICT
TRANSFORM FOR TYPE ndarray
%3$s
AS $func$
import numpy as np
# i is already a copy and the return will also be copied. No sense in a 3rd copy.
return np.array(i, copy=False)
$func$;
CREATE CAST (%5$s%2$s AS ndarray) WITH FUNCTION ndarray_from_%1$s(%5$s%2$s) %4$s;
$fmt$;
BEGIN
  -- FROM
  EXECUTE format(
    c_from_fmt
    , c_clean_type
    , '' -- Not array
    , transform
    , c_cast_type
    , c_regtype
  );

  -- TO
  EXECUTE format(
    c_to_fmt
    , c_clean_type
    , '' -- Not array
    , transform
    , c_cast_type
    , c_error_fmt -- Error on len(ndarray)>1
    , '' -- Return only first element
    , '' -- No function name decorator
    , c_regtype
  );

  /*
   * Array versions
   */
  IF create_array_cast THEN
    -- FROM
    EXECUTE format(
      c_from_fmt
      , c_clean_type
      , '[]' -- Array
      , transform
      , c_cast_type
      , c_regtype::text || '[]'
    );

    -- TO
    EXECUTE format(
      c_to_fmt
      , c_clean_type
      , '[]' -- Array
      , transform
      , c_cast_type
      , '' -- No error on len(ndarray)>1
      , '.tolist()' -- Return all elements
      , '_array' -- Function name decorator
      , c_regtype::text || '[]'
    );
  END IF;
END
$body$;

/*
 * Create casts for all standard pythonu supported types
 */
SELECT create_cast(t) FROM unnest('{boolean,smallint,int,bigint,float,real,numeric,text}'::text[]) t;

CREATE FUNCTION "panda_post Temp Schema".cf(
  fname text
  , extra_args text DEFAULT NULL
  , options text DEFAULT 'IMMUTABLE'
  , attribute boolean DEFAULT false
  , pgname text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $cf_body$
DECLARE
  c_pgname CONSTANT text := coalesce(pgname,fname);

  template CONSTANT text := $template$
/*
 * format() args:
 * 1: function name
 * 2: extra argument specifications
 * 3: function options
 * 4: return clause
 */
CREATE FUNCTION %1$I(
  i ndarray
%2$s) RETURNS ndarray LANGUAGE plpythonu %3$s
TRANSFORM FOR TYPE ndarray
AS $body$
import numpy as np
return %4$s
$body$;
$template$;

  temp_proc regprocedure;
  input_arg_names text;
  input_arg_types text;
  sql text;
BEGIN
  -- Get names of extra args by creating a temp function
  IF extra_args IS NOT NULL THEN
    sql := format(
      $fmt$CREATE FUNCTION pg_temp.nd_array_get_function_argument_names(
        i ndarray -- Must match template!!!
        %s
      ) RETURNS int LANGUAGE sql AS 'SELECT 1'
      $fmt$
      , extra_args
    );
    --RAISE DEBUG 'Executing SQL %', sql;
    EXECUTE sql;

    /*
     * Get new OID. *This must be done dynamically!* Otherwise we get stuck
     * with a CONST oid after first compilation.
     */
    EXECUTE $$SELECT 'pg_temp.nd_array_get_function_argument_names'::regproc::regprocedure$$ INTO temp_proc;
    SELECT
        array_to_string( proargnames, ', ' )
        , array_to_string( proargtypes::regtype[], ', ' )
      INTO STRICT input_arg_names, input_arg_types
      FROM pg_proc
      WHERE oid = temp_proc
    ;
    -- NOTE: DROP may not accept all the argument options that CREATE does, so use temp_proc
    EXECUTE format(
      $fmt$DROP FUNCTION %s$fmt$
      , temp_proc
    );
  END IF;

  sql := format(
    template
    , c_pgname
    , extra_args
    , options

    -- Return clause
    , CASE WHEN attribute THEN
        $$i.$$ || fname
      ELSE
        format(
          $$np.%1$s(%2$s)$$
          , fname
          , input_arg_names
        )
      END
  );
  RAISE DEBUG 'Executing SQL %', sql;
  EXECUTE sql;
END
$cf_body$;

SELECT "panda_post Temp Schema".cf(
  'T'
  , attribute := true
);

/*
 * ndall, ndany
 */
CREATE FUNCTION ndall(
  i ndarray
  , axis int[]
  , keepdims boolean=False
) RETURNS ndarray IMMUTABLE LANGUAGE plpythonu
TRANSFORM FOR TYPE ndarray
AS $body$
import numpy as np

if len(axis)==1:
  my_axis=axis[0]
else:
  my_axis=axis

# Can't do keepdims=keepdims
plpy.debug('my_axis={}, args={}'.format(my_axis, args))
out=np.all(i, axis=my_axis, keepdims=args[2])
plpy.debug('out={}'.format(repr(out)))

return out
$body$;
CREATE FUNCTION ndall(
  i ndarray
  , axis int
  , keepdims boolean=False
) RETURNS ndarray IMMUTABLE LANGUAGE sql AS $body$
SELECT ndall(i, array[axis], keepdims)
$body$;
CREATE FUNCTION ndall(
  i ndarray
  , keepdims boolean=False
) RETURNS ndarray LANGUAGE sql IMMUTABLE AS $$
SELECT ndall(i, NULL::int, keepdims)
$$;

CREATE FUNCTION ndany(
  i ndarray
  , axis int[]
  , keepdims boolean=False
) RETURNS ndarray IMMUTABLE LANGUAGE plpythonu
TRANSFORM FOR TYPE ndarray
AS $body$
import numpy as np

if len(axis)==1:
  my_axis=axis[0]
else:
  my_axis=axis

# Can't do keepdims=keepdims
plpy.debug('my_axis={}, args={}'.format(my_axis, args))
out=np.any(i, axis=my_axis, keepdims=args[2])
plpy.debug('out={}'.format(repr(out)))

return out
$body$;
CREATE FUNCTION ndany(
  i ndarray
  , axis int
  , keepdims boolean=False
) RETURNS ndarray IMMUTABLE LANGUAGE sql AS $body$
SELECT ndany(i, array[axis], keepdims)
$body$;
CREATE FUNCTION ndany(
  i ndarray
  , keepdims boolean=False
) RETURNS ndarray LANGUAGE sql IMMUTABLE AS $$
SELECT ndany(i, NULL::int, keepdims)
$$;

/*
 * repr()
 */
CREATE FUNCTION repr(
  i ndarray
) RETURNS text LANGUAGE plpythonu STRICT IMMUTABLE
TRANSFORM FOR TYPE ndarray
AS $body$
import numpy
return repr(i)
$body$;
CREATE FUNCTION str(
  i ndarray
) RETURNS text LANGUAGE plpythonu STRICT IMMUTABLE
TRANSFORM FOR TYPE ndarray
AS $body$
import numpy
return str(i)
$body$;
CREATE FUNCTION eval(
  i text
) RETURNS ndarray LANGUAGE plpythonu IMMUTABLE
TRANSFORM FOR TYPE ndarray
AS $body$
import numpy as np
# i is already a copy and the return will also be copied. No sense in a 3rd copy.
return np.array(eval(i), copy=False)
$body$;

SELECT "panda_post Temp Schema".cf(
  'ediff1d'
  , $$
  , to_end ndarray = NULL
  , to_begin ndarray = NULL
$$);
--SET client_min_messages=debug;
/*
setxor1d(ar1, ar2, assume_unique=False)
in1d(ar1, ar2, assume_unique=False, invert=False)
union1d(ar1, ar2)
setdiff1d(ar1, ar2, assume_unique=False)
*/
-- All of these also accept assume_unique, but it seems pointless to support that
SELECT "panda_post Temp Schema".cf( u, ', ar2 ndarray' ) FROM unnest(
  '{intersect1d,setxor1d,union1d,setdiff1d}'::text[]
) u;
SELECT "panda_post Temp Schema".cf(
  'in1d'
  , $$
  , ar2 ndarray
  , assume_unique boolean = False -- Include this only here preserve it's position
  , invert boolean = False
$$);

/*
 * Can't use generic template for unique
 */
-- Unique is a reserved word, so need to modify it anyway...
CREATE FUNCTION ndunique(
  ar ndarray
  , return_index boolean = False
  , return_inverse boolean = False
  , return_counts boolean = False
) RETURNS ndarray[] LANGUAGE plpythonu IMMUTABLE
TRANSFORM FOR TYPE ndarray
AS $body$
import numpy as np

if return_index or return_inverse or return_counts:
  return np.unique(ar, return_index, return_inverse, return_counts)
else:
  # Need to do this to ensure we always return an array
  return (np.unique(ar),)
$body$;
CREATE FUNCTION ndunique1(
  ar ndarray
) RETURNS ndarray LANGUAGE plpythonu IMMUTABLE
TRANSFORM FOR TYPE ndarray
AS $body$
import numpy as np

return np.unique(ar)
$body$;
COMMENT ON FUNCTION ndunique1(
  ar ndarray
) IS $$Version of ndarray.unique() that returns just the nd array$$;

-- Note that we can't use CASCADE or it will attempt to drop the extension that we're trying to create...
DROP FUNCTION "panda_post Temp Schema".cf(
  fname text
  , extra_args text --DEFAULT NULL
  , options text --DEFAULT 'IMMUTABLE'
  , attribute boolean --DEFAULT false
  , pgname text --DEFAULT NULL
);
DROP SCHEMA "panda_post Temp Schema";

-- vi: expandtab ts=2 sw=2
