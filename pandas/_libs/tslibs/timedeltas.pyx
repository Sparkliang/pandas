# -*- coding: utf-8 -*-
# cython: profile=False
import collections
import re

import sys
cdef bint PY3 = (sys.version_info[0] >= 3)

from cython cimport Py_ssize_t

from cpython cimport PyUnicode_Check, Py_NE, Py_EQ, PyObject_RichCompare

import numpy as np
cimport numpy as np
from numpy cimport int64_t, ndarray
np.import_array()

from cpython.datetime cimport (datetime, timedelta,
                               PyDateTime_CheckExact,
                               PyDateTime_Check, PyDelta_Check,
                               PyDateTime_IMPORT)
PyDateTime_IMPORT


cimport util
from util cimport (is_timedelta64_object, is_datetime64_object,
                   is_integer_object, is_float_object,
                   is_string_object)

from np_datetime cimport (cmp_scalar, reverse_ops, td64_to_tdstruct,
                          pandas_timedeltastruct)

from nattype import nat_strings, NaT
from nattype cimport checknull_with_nat, NPY_NAT

# ----------------------------------------------------------------------
# Constants

cdef int64_t DAY_NS = 86400000000000LL

# components named tuple
Components = collections.namedtuple('Components', [
    'days', 'hours', 'minutes', 'seconds',
    'milliseconds', 'microseconds', 'nanoseconds'])

cdef dict timedelta_abbrevs = { 'D': 'd',
                                'd': 'd',
                                'days': 'd',
                                'day': 'd',
                                'hours': 'h',
                                'hour': 'h',
                                'hr': 'h',
                                'h': 'h',
                                'm': 'm',
                                'minute': 'm',
                                'min': 'm',
                                'minutes': 'm',
                                's': 's',
                                'seconds': 's',
                                'sec': 's',
                                'second': 's',
                                'ms': 'ms',
                                'milliseconds': 'ms',
                                'millisecond': 'ms',
                                'milli': 'ms',
                                'millis': 'ms',
                                'us': 'us',
                                'microseconds': 'us',
                                'microsecond': 'us',
                                'micro': 'us',
                                'micros': 'us',
                                'ns': 'ns',
                                'nanoseconds': 'ns',
                                'nano': 'ns',
                                'nanos': 'ns',
                                'nanosecond': 'ns'}

_no_input = object()

# ----------------------------------------------------------------------

cpdef int64_t delta_to_nanoseconds(delta) except? -1:
    if util.is_array(delta):
        return delta.astype('m8[ns]').astype('int64')
    if hasattr(delta, 'nanos'):
        return delta.nanos
    if hasattr(delta, 'delta'):
        delta = delta.delta
    if is_timedelta64_object(delta):
        return delta.astype("timedelta64[ns]").item()
    if is_integer_object(delta):
        return delta

    return (delta.days * 24 * 60 * 60 * 1000000 +
            delta.seconds * 1000000 +
            delta.microseconds) * 1000


cpdef convert_to_timedelta64(object ts, object unit):
    """
    Convert an incoming object to a timedelta64 if possible

    Handle these types of objects:
        - timedelta/Timedelta
        - timedelta64
        - an offset
        - np.int64 (with unit providing a possible modifier)
        - None/NaT

    Return an ns based int64

    # kludgy here until we have a timedelta scalar
    # handle the numpy < 1.7 case
    """
    if checknull_with_nat(ts):
        return np.timedelta64(NPY_NAT)
    elif isinstance(ts, Timedelta):
        # already in the proper format
        ts = np.timedelta64(ts.value)
    elif is_datetime64_object(ts):
        # only accept a NaT here
        if ts.astype('int64') == NPY_NAT:
            return np.timedelta64(NPY_NAT)
    elif is_timedelta64_object(ts):
        ts = ts.astype("m8[{0}]".format(unit.lower()))
    elif is_integer_object(ts):
        if ts == NPY_NAT:
            return np.timedelta64(NPY_NAT)
        else:
            if util.is_array(ts):
                ts = ts.astype('int64').item()
            if unit in ['Y', 'M', 'W']:
                ts = np.timedelta64(ts, unit)
            else:
                ts = cast_from_unit(ts, unit)
                ts = np.timedelta64(ts)
    elif is_float_object(ts):
        if util.is_array(ts):
            ts = ts.astype('int64').item()
        if unit in ['Y', 'M', 'W']:
            ts = np.timedelta64(int(ts), unit)
        else:
            ts = cast_from_unit(ts, unit)
            ts = np.timedelta64(ts)
    elif is_string_object(ts):
        ts = np.timedelta64(parse_timedelta_string(ts))
    elif hasattr(ts, 'delta'):
        ts = np.timedelta64(delta_to_nanoseconds(ts), 'ns')

    if PyDelta_Check(ts):
        ts = np.timedelta64(delta_to_nanoseconds(ts), 'ns')
    elif not is_timedelta64_object(ts):
        raise ValueError("Invalid type for timedelta "
                         "scalar: {ts_type}".format(ts_type=type(ts)))
    return ts.astype('timedelta64[ns]')


cpdef array_to_timedelta64(ndarray[object] values, unit='ns', errors='raise'):
    """
    Convert an ndarray to an array of timedeltas. If errors == 'coerce',
    coerce non-convertible objects to NaT. Otherwise, raise.
    """

    cdef:
        Py_ssize_t i, n
        ndarray[int64_t] iresult

    if errors not in ('ignore', 'raise', 'coerce'):
        raise ValueError("errors must be one of 'ignore', "
                         "'raise', or 'coerce'}")

    n = values.shape[0]
    result = np.empty(n, dtype='m8[ns]')
    iresult = result.view('i8')

    # Usually, we have all strings. If so, we hit the fast path.
    # If this path fails, we try conversion a different way, and
    # this is where all of the error handling will take place.
    try:
        for i in range(n):
            result[i] = parse_timedelta_string(values[i])
    except:
        for i in range(n):
            try:
                result[i] = convert_to_timedelta64(values[i], unit)
            except ValueError:
                if errors == 'coerce':
                    result[i] = NPY_NAT
                else:
                    raise

    return iresult


cpdef inline int64_t cast_from_unit(object ts, object unit) except? -1:
    """ return a casting of the unit represented to nanoseconds
        round the fractional part of a float to our precision, p """
    cdef:
        int64_t m
        int p

    if unit == 'D' or unit == 'd':
        m = 1000000000L * 86400
        p = 6
    elif unit == 'h':
        m = 1000000000L * 3600
        p = 6
    elif unit == 'm':
        m = 1000000000L * 60
        p = 6
    elif unit == 's':
        m = 1000000000L
        p = 6
    elif unit == 'ms':
        m = 1000000L
        p = 3
    elif unit == 'us':
        m = 1000L
        p = 0
    elif unit == 'ns' or unit is None:
        m = 1L
        p = 0
    else:
        raise ValueError("cannot cast unit {0}".format(unit))

    # just give me the unit back
    if ts is None:
        return m

    # cast the unit, multiply base/frace separately
    # to avoid precision issues from float -> int
    base = <int64_t> ts
    frac = ts -base
    if p:
        frac = round(frac, p)
    return <int64_t> (base *m) + <int64_t> (frac *m)


cdef inline parse_timedelta_string(object ts):
    """
    Parse a regular format timedelta string. Return an int64_t (in ns)
    or raise a ValueError on an invalid parse.
    """

    cdef:
        unicode c
        bint neg=0, have_dot=0, have_value=0, have_hhmmss=0
        object current_unit=None
        int64_t result=0, m=0, r
        list number=[], frac=[], unit=[]

    # neg : tracks if we have a leading negative for the value
    # have_dot : tracks if we are processing a dot (either post hhmmss or
    #            inside an expression)
    # have_value : track if we have at least 1 leading unit
    # have_hhmmss : tracks if we have a regular format hh:mm:ss

    if len(ts) == 0 or ts in nat_strings:
        return NPY_NAT

    # decode ts if necessary
    if not PyUnicode_Check(ts) and not PY3:
        ts = str(ts).decode('utf-8')

    for c in ts:

        # skip whitespace / commas
        if c == ' ' or c == ',':
            pass

        # positive signs are ignored
        elif c == '+':
            pass

        # neg
        elif c == '-':

            if neg or have_value or have_hhmmss:
                raise ValueError("only leading negative signs are allowed")

            neg = 1

        # number (ascii codes)
        elif ord(c) >= 48 and ord(c) <= 57:

            if have_dot:

                # we found a dot, but now its just a fraction
                if len(unit):
                    number.append(c)
                    have_dot = 0
                else:
                    frac.append(c)

            elif not len(unit):
                number.append(c)

            else:
                r = timedelta_from_spec(number, frac, unit)
                unit, number, frac = [], [c], []

                result += timedelta_as_neg(r, neg)

        # hh:mm:ss.
        elif c == ':':

            # we flip this off if we have a leading value
            if have_value:
                neg = 0

            # we are in the pattern hh:mm:ss pattern
            if len(number):
                if current_unit is None:
                    current_unit = 'h'
                    m = 1000000000L * 3600
                elif current_unit == 'h':
                    current_unit = 'm'
                    m = 1000000000L * 60
                elif current_unit == 'm':
                    current_unit = 's'
                    m = 1000000000L
                r = <int64_t> int(''.join(number)) * m
                result += timedelta_as_neg(r, neg)
                have_hhmmss = 1
            else:
                raise ValueError("expecting hh:mm:ss format, "
                                 "received: {0}".format(ts))

            unit, number = [], []

        # after the decimal point
        elif c == '.':

            if len(number) and current_unit is not None:

                # by definition we had something like
                # so we need to evaluate the final field from a
                # hh:mm:ss (so current_unit is 'm')
                if current_unit != 'm':
                    raise ValueError("expected hh:mm:ss format before .")
                m = 1000000000L
                r = <int64_t> int(''.join(number)) * m
                result += timedelta_as_neg(r, neg)
                have_value = 1
                unit, number, frac = [], [], []

            have_dot = 1

        # unit
        else:
            unit.append(c)
            have_value = 1
            have_dot = 0

    # we had a dot, but we have a fractional
    # value since we have an unit
    if have_dot and len(unit):
        r = timedelta_from_spec(number, frac, unit)
        result += timedelta_as_neg(r, neg)

    # we have a dot as part of a regular format
    # e.g. hh:mm:ss.fffffff
    elif have_dot:

        if ((len(number) or len(frac)) and not len(unit)
                and current_unit is None):
            raise ValueError("no units specified")

        if len(frac) > 0 and len(frac) <= 3:
            m = 10**(3 -len(frac)) * 1000L * 1000L
        elif len(frac) > 3 and len(frac) <= 6:
            m = 10**(6 -len(frac)) * 1000L
        else:
            m = 10**(9 -len(frac))

        r = <int64_t> int(''.join(frac)) * m
        result += timedelta_as_neg(r, neg)

    # we have a regular format
    # we must have seconds at this point (hence the unit is still 'm')
    elif current_unit is not None:
        if current_unit != 'm':
            raise ValueError("expected hh:mm:ss format")
        m = 1000000000L
        r = <int64_t> int(''.join(number)) * m
        result += timedelta_as_neg(r, neg)

    # we have a last abbreviation
    elif len(unit):
        if len(number):
            r = timedelta_from_spec(number, frac, unit)
            result += timedelta_as_neg(r, neg)
        else:
            raise ValueError("unit abbreviation w/o a number")

    # treat as nanoseconds
    # but only if we don't have anything else
    else:
        if have_value:
            raise ValueError("have leftover units")
        if len(number):
            r = timedelta_from_spec(number, frac, 'ns')
            result += timedelta_as_neg(r, neg)

    return result


cdef inline int64_t timedelta_as_neg(int64_t value, bint neg):
    """

    Parameters
    ----------
    value : int64_t of the timedelta value
    neg : boolean if the a negative value
    """
    if neg:
        return -value
    return value


cdef inline timedelta_from_spec(object number, object frac, object unit):
    """

    Parameters
    ----------
    number : a list of number digits
    frac : a list of frac digits
    unit : a list of unit characters
    """
    cdef object n

    try:
        unit = ''.join(unit)
        unit = timedelta_abbrevs[unit.lower()]
    except KeyError:
        raise ValueError("invalid abbreviation: {0}".format(unit))

    n = ''.join(number) + '.' + ''.join(frac)
    return cast_from_unit(float(n), unit)


# ----------------------------------------------------------------------
# Timedelta ops utilities

cdef bint _validate_ops_compat(other):
    # return True if we are compat with operating
    if checknull_with_nat(other):
        return True
    elif PyDelta_Check(other) or is_timedelta64_object(other):
        return True
    elif is_string_object(other):
        return True
    elif hasattr(other, 'delta'):
        return True
    return False


def _op_unary_method(func, name):
    def f(self):
        return Timedelta(func(self.value), unit='ns')
    f.__name__ = name
    return f


def _binary_op_method_timedeltalike(op, name):
    # define a binary operation that only works if the other argument is
    # timedelta like or an array of timedeltalike
    def f(self, other):
        if hasattr(other, 'delta') and not PyDelta_Check(other):
            # offsets.Tick
            return op(self, other.delta)

        elif other is NaT:
            return NaT

        elif is_datetime64_object(other) or PyDateTime_CheckExact(other):
            # the PyDateTime_CheckExact case is for a datetime object that
            # is specifically *not* a Timestamp, as the Timestamp case will be
            # handled after `_validate_ops_compat` returns False below
            from ..tslib import Timestamp
            return op(self, Timestamp(other))
            # We are implicitly requiring the canonical behavior to be
            # defined by Timestamp methods.

        elif hasattr(other, 'dtype'):
            # nd-array like
            if other.dtype.kind not in ['m', 'M']:
                # raise rathering than letting numpy return wrong answer
                return NotImplemented
            return op(self.to_timedelta64(), other)

        elif not _validate_ops_compat(other):
            return NotImplemented

        try:
            other = Timedelta(other)
        except ValueError:
            # failed to parse as timedelta
            return NotImplemented

        return Timedelta(op(self.value, other.value), unit='ns')

    f.__name__ = name
    return f


# ----------------------------------------------------------------------
# Timedelta Construction

iso_pater = re.compile(r"""P
                        (?P<days>-?[0-9]*)DT
                        (?P<hours>[0-9]{1,2})H
                        (?P<minutes>[0-9]{1,2})M
                        (?P<seconds>[0-9]{0,2})
                        (\.
                        (?P<milliseconds>[0-9]{1,3})
                        (?P<microseconds>[0-9]{0,3})
                        (?P<nanoseconds>[0-9]{0,3})
                        )?S""", re.VERBOSE)


cdef int64_t parse_iso_format_string(object iso_fmt) except? -1:
    """
    Extracts and cleanses the appropriate values from a match object with
    groups for each component of an ISO 8601 duration

    Parameters
    ----------
    iso_fmt:
        ISO 8601 Duration formatted string

    Returns
    -------
    ns: int64_t
        Precision in nanoseconds of matched ISO 8601 duration

    Raises
    ------
    ValueError
        If ``iso_fmt`` cannot be parsed
    """

    cdef int64_t ns = 0

    match = re.match(iso_pater, iso_fmt)
    if match:
        match_dict = match.groupdict(default='0')
        for comp in ['milliseconds', 'microseconds', 'nanoseconds']:
            match_dict[comp] = '{:0<3}'.format(match_dict[comp])

        for k, v in match_dict.items():
            ns += timedelta_from_spec(v, '0', k)

    else:
        raise ValueError("Invalid ISO 8601 Duration format - "
                         "{}".format(iso_fmt))

    return ns


cdef _to_py_int_float(v):
    # Note: This used to be defined inside Timedelta.__new__
    # but cython will not allow `cdef` functions to be defined dynamically.
    if is_integer_object(v):
        return int(v)
    elif is_float_object(v):
        return float(v)
    raise TypeError("Invalid type {0}. Must be int or "
                    "float.".format(type(v)))


# Similar to Timestamp/datetime, this is a construction requirement for
# timedeltas that we need to do object instantiation in python. This will
# serve as a C extension type that shadows the Python class, where we do any
# heavy lifting.
cdef class _Timedelta(timedelta):
    cdef readonly:
        int64_t value      # nanoseconds
        object freq        # frequency reference
        bint is_populated  # are my components populated
        int64_t _d, _h, _m, _s, _ms, _us, _ns

    # higher than np.ndarray and np.matrix
    __array_priority__ = 100

    def __hash__(_Timedelta self):
        if self._has_ns():
            return hash(self.value)
        else:
            return timedelta.__hash__(self)

    def __richcmp__(_Timedelta self, object other, int op):
        cdef:
            _Timedelta ots
            int ndim

        if isinstance(other, _Timedelta):
            ots = other
        elif PyDelta_Check(other):
            ots = Timedelta(other)
        else:
            ndim = getattr(other, "ndim", -1)

            if ndim != -1:
                if ndim == 0:
                    if is_timedelta64_object(other):
                        other = Timedelta(other)
                    else:
                        if op == Py_EQ:
                            return False
                        elif op == Py_NE:
                            return True

                        # only allow ==, != ops
                        raise TypeError('Cannot compare type {!r} with type ' \
                                        '{!r}'.format(type(self).__name__,
                                                      type(other).__name__))
                if util.is_array(other):
                    return PyObject_RichCompare(np.array([self]), other, op)
                return PyObject_RichCompare(other, self, reverse_ops[op])
            else:
                if op == Py_EQ:
                    return False
                elif op == Py_NE:
                    return True
                raise TypeError('Cannot compare type {!r} with type ' \
                                '{!r}'.format(type(self).__name__,
                                              type(other).__name__))

        return cmp_scalar(self.value, ots.value, op)

    cpdef bint _has_ns(self):
        return self.value % 1000 != 0

    def _ensure_components(_Timedelta self):
        """
        compute the components
        """
        if self.is_populated:
            return

        cdef:
            pandas_timedeltastruct tds

        td64_to_tdstruct(self.value, &tds)
        self._d = tds.days
        self._h = tds.hrs
        self._m = tds.min
        self._s = tds.sec
        self._ms = tds.ms
        self._us = tds.us
        self._ns = tds.ns
        self._seconds = tds.seconds
        self._microseconds = tds.microseconds

        self.is_populated = 1

    cpdef timedelta to_pytimedelta(_Timedelta self):
        """
        return an actual datetime.timedelta object
        note: we lose nanosecond resolution if any
        """
        return timedelta(microseconds=int(self.value) / 1000)

    def to_timedelta64(self):
        """ Returns a numpy.timedelta64 object with 'ns' precision """
        return np.timedelta64(self.value, 'ns')

    def total_seconds(self):
        """
        Total duration of timedelta in seconds (to ns precision)
        """
        return 1e-9 * self.value

    def view(self, dtype):
        """ array view compat """
        return np.timedelta64(self.value).view(dtype)

    @property
    def components(self):
        """ Return a Components NamedTuple-like """
        self._ensure_components()
        # return the named tuple
        return Components(self._d, self._h, self._m, self._s,
                          self._ms, self._us, self._ns)

    @property
    def delta(self):
        """ return out delta in ns (for internal compat) """
        return self.value

    @property
    def asm8(self):
        """ return a numpy timedelta64 array view of myself """
        return np.int64(self.value).view('m8[ns]')

    @property
    def resolution(self):
        """ return a string representing the lowest resolution that we have """

        self._ensure_components()
        if self._ns:
            return "N"
        elif self._us:
            return "U"
        elif self._ms:
            return "L"
        elif self._s:
            return "S"
        elif self._m:
            return "T"
        elif self._h:
            return "H"
        else:
            return "D"

    @property
    def nanoseconds(self):
        """
        Number of nanoseconds (>= 0 and less than 1 microsecond).

        .components will return the shown components
        """
        self._ensure_components()
        return self._ns

    def _repr_base(self, format=None):
        """

        Parameters
        ----------
        format : None|all|sub_day|long

        Returns
        -------
        converted : string of a Timedelta

        """
        cdef object sign, seconds_pretty, subs, fmt, comp_dict

        self._ensure_components()

        if self._d < 0:
            sign = " +"
        else:
            sign = " "

        if format == 'all':
            fmt = "{days} days{sign}{hours:02}:{minutes:02}:{seconds:02}." \
                  "{milliseconds:03}{microseconds:03}{nanoseconds:03}"
        else:
            # if we have a partial day
            subs = (self._h or self._m or self._s or
                    self._ms or self._us or self._ns)

            # by default not showing nano
            if self._ms or self._us or self._ns:
                seconds_fmt = "{seconds:02}.{milliseconds:03}{microseconds:03}"
            else:
                seconds_fmt = "{seconds:02}"

            if format == 'sub_day' and not self._d:
                fmt = "{hours:02}:{minutes:02}:" + seconds_fmt
            elif subs or format == 'long':
                fmt = "{days} days{sign}{hours:02}:{minutes:02}:" + seconds_fmt
            else:
                fmt = "{days} days"

        comp_dict = self.components._asdict()
        comp_dict['sign'] = sign

        return fmt.format(**comp_dict)

    def __repr__(self):
        return "Timedelta('{0}')".format(self._repr_base(format='long'))

    def __str__(self):
        return self._repr_base(format='long')

    def isoformat(self):
        """
        Format Timedelta as ISO 8601 Duration like
        ``P[n]Y[n]M[n]DT[n]H[n]M[n]S``, where the ``[n]`` s are replaced by the
        values. See https://en.wikipedia.org/wiki/ISO_8601#Durations

        .. versionadded:: 0.20.0

        Returns
        -------
        formatted : str

        Notes
        -----
        The longest component is days, whose value may be larger than
        365.
        Every component is always included, even if its value is 0.
        Pandas uses nanosecond precision, so up to 9 decimal places may
        be included in the seconds component.
        Trailing 0's are removed from the seconds component after the decimal.
        We do not 0 pad components, so it's `...T5H...`, not `...T05H...`

        Examples
        --------
        >>> td = pd.Timedelta(days=6, minutes=50, seconds=3,
        ...                   milliseconds=10, microseconds=10, nanoseconds=12)
        >>> td.isoformat()
        'P6DT0H50M3.010010012S'
        >>> pd.Timedelta(hours=1, seconds=10).isoformat()
        'P0DT0H0M10S'
        >>> pd.Timedelta(hours=1, seconds=10).isoformat()
        'P0DT0H0M10S'
        >>> pd.Timedelta(days=500.5).isoformat()
        'P500DT12H0MS'

        See Also
        --------
        Timestamp.isoformat
        """
        components = self.components
        seconds = '{}.{:0>3}{:0>3}{:0>3}'.format(components.seconds,
                                                 components.milliseconds,
                                                 components.microseconds,
                                                 components.nanoseconds)
        # Trim unnecessary 0s, 1.000000000 -> 1
        seconds = seconds.rstrip('0').rstrip('.')
        tpl = 'P{td.days}DT{td.hours}H{td.minutes}M{seconds}S'.format(
            td=components, seconds=seconds)
        return tpl


# Python front end to C extension type _Timedelta
# This serves as the box for timedelta64

class Timedelta(_Timedelta):
    """
    Represents a duration, the difference between two dates or times.

    Timedelta is the pandas equivalent of python's ``datetime.timedelta``
    and is interchangable with it in most cases.

    Parameters
    ----------
    value : Timedelta, timedelta, np.timedelta64, string, or integer
    unit : string, {'ns', 'us', 'ms', 's', 'm', 'h', 'D'}, optional
        Denote the unit of the input, if input is an integer. Default 'ns'.
    days, seconds, microseconds,
    milliseconds, minutes, hours, weeks : numeric, optional
        Values for construction in compat with datetime.timedelta.
        np ints and floats will be coereced to python ints and floats.

    Notes
    -----
    The ``.value`` attribute is always in ns.

    """
    def __new__(cls, object value=_no_input, unit=None, **kwargs):
        cdef _Timedelta td_base

        if value is _no_input:
            if not len(kwargs):
                raise ValueError("cannot construct a Timedelta without a "
                                 "value/unit or descriptive keywords "
                                 "(days,seconds....)")

            kwargs = {key: _to_py_int_float(kwargs[key]) for key in kwargs}

            nano = kwargs.pop('nanoseconds', 0)
            try:
                value = nano + convert_to_timedelta64(timedelta(**kwargs),
                                                      'ns')
            except TypeError as e:
                raise ValueError("cannot construct a Timedelta from the "
                                 "passed arguments, allowed keywords are "
                                 "[weeks, days, hours, minutes, seconds, "
                                 "milliseconds, microseconds, nanoseconds]")

        if isinstance(value, Timedelta):
            value = value.value
        elif is_string_object(value):
            if len(value) > 0 and value[0] == 'P':
                value = parse_iso_format_string(value)
            else:
                value = parse_timedelta_string(value)
            value = np.timedelta64(value)
        elif PyDelta_Check(value):
            value = convert_to_timedelta64(value, 'ns')
        elif is_timedelta64_object(value):
            if unit is not None:
                value = value.astype('timedelta64[{0}]'.format(unit))
            value = value.astype('timedelta64[ns]')
        elif hasattr(value, 'delta'):
            value = np.timedelta64(delta_to_nanoseconds(value.delta), 'ns')
        elif is_integer_object(value) or is_float_object(value):
            # unit=None is de-facto 'ns'
            value = convert_to_timedelta64(value, unit)
        elif checknull_with_nat(value):
            return NaT
        else:
            raise ValueError(
                "Value must be Timedelta, string, integer, "
                "float, timedelta or convertible")

        if is_timedelta64_object(value):
            value = value.view('i8')

        # nat
        if value == NPY_NAT:
            return NaT

        # make timedelta happy
        td_base = _Timedelta.__new__(cls, microseconds=int(value) / 1000)
        td_base.value = value
        td_base.is_populated = 0
        return td_base

    def __setstate__(self, state):
        (value) = state
        self.value = value

    def __reduce__(self):
        object_state = self.value,
        return (Timedelta, object_state)

    def _round(self, freq, rounder):
        cdef:
            int64_t result, unit

        from pandas.tseries.frequencies import to_offset
        unit = to_offset(freq).nanos
        result = unit * rounder(self.value / float(unit))
        return Timedelta(result, unit='ns')

    def round(self, freq):
        """
        Round the Timedelta to the specified resolution

        Returns
        -------
        a new Timedelta rounded to the given resolution of `freq`

        Parameters
        ----------
        freq : a freq string indicating the rounding resolution

        Raises
        ------
        ValueError if the freq cannot be converted
        """
        return self._round(freq, np.round)

    def floor(self, freq):
        """
        return a new Timedelta floored to this resolution

        Parameters
        ----------
        freq : a freq string indicating the flooring resolution
        """
        return self._round(freq, np.floor)

    def ceil(self, freq):
        """
        return a new Timedelta ceiled to this resolution

        Parameters
        ----------
        freq : a freq string indicating the ceiling resolution
        """
        return self._round(freq, np.ceil)

    # ----------------------------------------------------------------
    # Arithmetic Methods
    # TODO: Can some of these be defined in the cython class?

    __inv__ = _op_unary_method(lambda x: -x, '__inv__')
    __neg__ = _op_unary_method(lambda x: -x, '__neg__')
    __pos__ = _op_unary_method(lambda x: x, '__pos__')
    __abs__ = _op_unary_method(lambda x: abs(x), '__abs__')

    __add__ = _binary_op_method_timedeltalike(lambda x, y: x + y, '__add__')
    __radd__ = _binary_op_method_timedeltalike(lambda x, y: x + y, '__radd__')
    __sub__ = _binary_op_method_timedeltalike(lambda x, y: x - y, '__sub__')
    __rsub__ = _binary_op_method_timedeltalike(lambda x, y: y - x, '__rsub__')

    def __mul__(self, other):
        if hasattr(other, 'dtype'):
            # ndarray-like
            return other * self.to_timedelta64()

        elif other is NaT:
            return NaT

        elif not (is_integer_object(other) or is_float_object(other)):
            # only integers and floats allowed
            return NotImplemented

        return Timedelta(other * self.value, unit='ns')

    __rmul__ = __mul__

    def __truediv__(self, other):
        if hasattr(other, 'dtype'):
            return self.to_timedelta64() / other

        elif is_integer_object(other) or is_float_object(other):
            # integers or floats
            return Timedelta(self.value / other, unit='ns')

        elif not _validate_ops_compat(other):
            return NotImplemented

        other = Timedelta(other)
        if other is NaT:
            return np.nan
        return self.value / float(other.value)

    def __rtruediv__(self, other):
        if hasattr(other, 'dtype'):
            return other / self.to_timedelta64()

        elif not _validate_ops_compat(other):
            return NotImplemented

        other = Timedelta(other)
        if other is NaT:
            return NaT
        return float(other.value) / self.value

    if not PY3:
        __div__ = __truediv__
        __rdiv__ = __rtruediv__

    def __floordiv__(self, other):
        # numpy does not implement floordiv for timedelta64 dtype, so we cannot
        # just defer
        if hasattr(other, '_typ'):
            # Series, DataFrame, ...
            return NotImplemented

        if hasattr(other, 'dtype'):
            if other.dtype.kind == 'm':
                # also timedelta-like
                return _broadcast_floordiv_td64(self.value, other, _floordiv)
            elif other.dtype.kind in ['i', 'u', 'f']:
                if other.ndim == 0:
                    return Timedelta(self.value // other)
                else:
                    return self.to_timedelta64() // other

            raise TypeError('Invalid dtype {dtype} for '
                            '{op}'.format(dtype=other.dtype,
                                          op='__floordiv__'))

        elif is_integer_object(other) or is_float_object(other):
            return Timedelta(self.value // other, unit='ns')

        elif not _validate_ops_compat(other):
            return NotImplemented

        other = Timedelta(other)
        if other is NaT:
            return np.nan
        return self.value // other.value

    def __rfloordiv__(self, other):
        # numpy does not implement floordiv for timedelta64 dtype, so we cannot
        # just defer
        if hasattr(other, '_typ'):
            # Series, DataFrame, ...
            return NotImplemented

        if hasattr(other, 'dtype'):
            if other.dtype.kind == 'm':
                # also timedelta-like
                return _broadcast_floordiv_td64(self.value, other, _rfloordiv)
            raise TypeError('Invalid dtype {dtype} for '
                            '{op}'.format(dtype=other.dtype,
                                          op='__floordiv__'))

        if is_float_object(other) and util._checknull(other):
            # i.e. np.nan
            return NotImplemented
        elif not _validate_ops_compat(other):
            return NotImplemented

        other = Timedelta(other)
        if other is NaT:
            return np.nan
        return other.value // self.value


cdef _floordiv(int64_t value, right):
    return value // right


cdef _rfloordiv(int64_t value, right):
    # analogous to referencing operator.div, but there is no operator.rfloordiv
    return right // value


cdef _broadcast_floordiv_td64(int64_t value, object other,
                              object (*operation)(int64_t value,
                                                  object right)):
    """Boilerplate code shared by Timedelta.__floordiv__ and
    Timedelta.__rfloordiv__ because np.timedelta64 does not implement these.

    Parameters
    ----------
    value : int64_t; `self.value` from a Timedelta object
    other : object
    operation : function, either _floordiv or _rfloordiv

    Returns
    -------
    result : varies based on `other`
    """
    # assumes other.dtype.kind == 'm', i.e. other is timedelta-like
    cdef:
        int ndim = getattr(other, 'ndim', -1)

    # We need to watch out for np.timedelta64('NaT').
    mask = other.view('i8') == NPY_NAT

    if ndim == 0:
        if mask:
            return np.nan

        return operation(value, other.astype('m8[ns]').astype('i8'))

    else:
        res = operation(value, other.astype('m8[ns]').astype('i8'))

        if mask.any():
            res = res.astype('f8')
            res[mask] = np.nan
        return res


# resolution in ns
Timedelta.min = Timedelta(np.iinfo(np.int64).min + 1)
Timedelta.max = Timedelta(np.iinfo(np.int64).max)
