cmake_minimum_required(VERSION 2.8.3)
project(bitbots_buttons)

find_package(catkin REQUIRED COMPONENTS message_generation humanoid_league_msgs rospy bitbots_msgs std_msgs bitbots_docs)
catkin_python_setup()

## Generate messages in the 'msg' folder
add_message_files(FILES Buttons.msg)

## Generate added messages and services with any dependencies listed here
generate_messages(DEPENDENCIES std_msgs)

catkin_package(CATKIN_DEPENDS std_msgs message_runtime)

enable_bitbots_docs()
