#!/usr/bin/env python

from distutils.core import setup
from catkin_pkg.python_setup import generate_distutils_setup

d = generate_distutils_setup(
    packages=['bitbots_hardware_rqt'],
    package_dir={'': 'src'},
    #scripts=['scripts/motion_viz']
)

setup(**d)
